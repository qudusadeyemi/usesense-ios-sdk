#if canImport(UIKit) && canImport(SwiftUI) && canImport(AVFoundation)
import UIKit
import SwiftUI

/// Hosted enrollment flow orchestrator per spec Section 10.1.
///
/// State machine: loading -> introduction -> capture -> finalizing -> result
///
/// Usage:
/// ```swift
/// let vc = HostedEnrollmentViewController(
///     enrollmentId: "enr_abc123",
///     config: config,
///     sdkBranding: branding,
///     onComplete: { result in print(result) }
/// )
/// present(vc, animated: true)
/// ```
public final class HostedEnrollmentViewController: UIViewController {

    // MARK: - Types

    enum PageStep: String {
        case loading
        case error
        case introduction
        case capture
        case finalizing
        case result
    }

    // MARK: - Properties

    private let enrollmentId: String
    private let config: UseSenseConfig
    private let sdkBranding: UseSenseBranding?
    private var onComplete: ((Result<String, UseSenseError>) -> Void)?

    private lazy var apiClient = UseSenseAPIClient(config: config)
    private var enrollmentData: RemoteEnrollmentData?
    private var branding: EffectiveBranding = EffectiveBranding()
    private var session: UseSenseSession?
    private var captureDecision: String?
    private var hostingController: UIHostingController<AnyView>?

    private var currentStep: PageStep = .loading {
        didSet { updateUI() }
    }
    private var errorTitle: String = "Session Not Available"
    private var errorMessage: String = "Something went wrong."

    // MARK: - Init

    public init(
        enrollmentId: String,
        config: UseSenseConfig,
        sdkBranding: UseSenseBranding? = nil,
        onComplete: @escaping (Result<String, UseSenseError>) -> Void
    ) {
        self.enrollmentId = enrollmentId
        self.config = config
        self.sdkBranding = sdkBranding
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        updateUI()
        Task { await loadEnrollmentData() }
    }

    // MARK: - Flow Steps

    private func loadEnrollmentData() async {
        currentStep = .loading
        do {
            let data = try await apiClient.getRemoteEnrollmentData(enrollmentId: enrollmentId)
            self.enrollmentData = data
            self.branding = EffectiveBranding.merge(sdk: sdkBranding, server: data.branding)

            // Mark as opened (fire-and-forget)
            Task { try? await apiClient.markEnrollmentOpened(enrollmentId: enrollmentId) }

            currentStep = .introduction
        } catch {
            errorTitle = "Session Not Available"
            errorMessage = (error as? UseSenseError)?.message ?? error.localizedDescription
            currentStep = .error
        }
    }

    private func startCapture() async {
        currentStep = .loading
        do {
            let initResponse = try await apiClient.initEnrollmentSession(enrollmentId: enrollmentId)

            // Create a session using the credentials from init-session
            let session = UseSenseSession(
                config: config,
                sessionType: .enrollment,
                eventEmitter: EventEmitter()
            )
            self.session = session

            // Inject the session data from the hosted init response
            session.injectHostedSessionData(initResponse.toCreateSessionResponse())

            currentStep = .capture
        } catch {
            errorTitle = "Failed to Start"
            errorMessage = (error as? UseSenseError)?.message ?? error.localizedDescription
            currentStep = .error
        }
    }

    private func handleCaptureComplete(_ result: Result<RedactedDecisionObject, UseSenseError>) async {
        currentStep = .finalizing
        self.captureDecision = (try? result.get())?.decision

        do {
            let completeResult = try await apiClient.completeRemoteEnrollment(enrollmentId: enrollmentId)
            // Use the remote complete status, falling back to capture decision
            let finalDecision = completeResult.decision ?? captureDecision ?? "REJECT"
            self.captureDecision = finalDecision
        } catch {
            // Spec: STILL show result - never leave user stuck
            if captureDecision == nil {
                captureDecision = "REJECT"
            }
        }
        currentStep = .result
    }

    // MARK: - UI Rendering

    private func updateUI() {
        guard isViewLoaded, view.window != nil || currentStep == .loading else {
            // Defer UI update until view is visible. Re-trigger on viewDidAppear if needed.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isViewLoaded else { return }
                self.renderCurrentStep()
            }
            return
        }
        renderCurrentStep()
    }

    private func renderCurrentStep() {
        let view: AnyView
        switch currentStep {
        case .loading:
            view = AnyView(HostedLoadingView(branding: branding))

        case .error:
            view = AnyView(HostedErrorView(branding: branding, title: errorTitle, message: errorMessage))

        case .introduction:
            view = AnyView(EnrollmentIntroductionView(
                branding: branding,
                onGetStarted: { [weak self] in
                    Task { await self?.startCapture() }
                }
            ))

        case .capture:
            if let session = session {
                view = AnyView(UseSenseView(
                    session: session,
                    onComplete: { [weak self] result in
                        Task { await self?.handleCaptureComplete(result) }
                    },
                    onCancel: { [weak self] in
                        self?.onComplete?(.failure(UseSenseError(code: .userCancelled)))
                        self?.dismiss(animated: true)
                    }
                ))
            } else {
                view = AnyView(HostedLoadingView(branding: branding))
            }

        case .finalizing:
            view = AnyView(HostedFinalizingView(branding: branding, title: "Finalizing Enrollment"))

        case .result:
            view = AnyView(HostedResultView(
                branding: branding,
                decision: captureDecision ?? "REJECT",
                flowType: .enrollment,
                actionText: nil,
                successMessage: enrollmentData?.successMessage,
                errorMessage: enrollmentData?.errorMessage,
                reviewMessage: nil,
                orgName: branding.displayName,
                onClose: { [weak self] in
                    self?.onComplete?(.success(self?.captureDecision ?? "REJECT"))
                    self?.dismiss(animated: true)
                }
            ))
        }

        setHostedView(view)
    }

    private func setHostedView(_ swiftUIView: AnyView) {
        if let existing = hostingController {
            existing.rootView = swiftUIView
        } else {
            let hosting = UIHostingController(rootView: swiftUIView)
            hostingController = hosting
            addChild(hosting)
            self.view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }
    }
}

// MARK: - Finalizing View

struct HostedFinalizingView: View {
    let branding: EffectiveBranding
    let title: String

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 0) {
            HostedPageHeader(branding: branding)
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color(red: 0.886, green: 0.910, blue: 0.878), lineWidth: 4)
                        .frame(width: 64, height: 64)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color(hex: branding.primaryColor), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
                }

                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(red: 0.059, green: 0.090, blue: 0.165))

                Text("Please wait...")
                    .font(.system(size: 15))
                    .foregroundColor(Color(red: 0.278, green: 0.333, blue: 0.412))
            }
            Spacer()
            HostedPageFooter()
        }
        .background(Color.white.ignoresSafeArea())
        .onAppear { isAnimating = true }
    }
}
#endif
