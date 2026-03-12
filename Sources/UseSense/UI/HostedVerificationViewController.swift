#if canImport(UIKit) && canImport(SwiftUI) && canImport(AVFoundation)
import UIKit
import SwiftUI

/// Hosted verification flow orchestrator per spec Section 10.2.
///
/// State machine: loading -> action-review -> capture -> finalizing -> result
///
/// Usage:
/// ```swift
/// let vc = HostedVerificationViewController(
///     remoteSessionId: "rsess_abc123",
///     config: config,
///     sdkBranding: branding,
///     onComplete: { result in print(result) }
/// )
/// present(vc, animated: true)
/// ```
public final class HostedVerificationViewController: UIViewController {

    // MARK: - Types

    enum PageStep: String {
        case loading
        case error
        case actionReview
        case capture
        case finalizing
        case result
    }

    // MARK: - Properties

    private let remoteSessionId: String
    private let config: UseSenseConfig
    private let sdkBranding: UseSenseBranding?
    private var onComplete: ((Result<String, UseSenseError>) -> Void)?

    private lazy var apiClient = UseSenseAPIClient(config: config)
    private var sessionData: RemoteSessionData?
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
        remoteSessionId: String,
        config: UseSenseConfig,
        sdkBranding: UseSenseBranding? = nil,
        onComplete: @escaping (Result<String, UseSenseError>) -> Void
    ) {
        self.remoteSessionId = remoteSessionId
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
        Task { await loadSessionData() }
    }

    // MARK: - Flow Steps

    private func loadSessionData() async {
        currentStep = .loading
        do {
            let data = try await apiClient.getRemoteSessionData(sessionId: remoteSessionId)
            self.sessionData = data
            self.branding = EffectiveBranding.merge(sdk: sdkBranding, server: data.branding)

            // Mark as opened (fire-and-forget)
            Task { try? await apiClient.markSessionOpened(sessionId: remoteSessionId) }

            currentStep = .actionReview
        } catch {
            errorTitle = "Session Not Available"
            errorMessage = (error as? UseSenseError)?.message ?? error.localizedDescription
            currentStep = .error
        }
    }

    private func startCapture() async {
        currentStep = .loading
        do {
            let initResponse = try await apiClient.initRemoteSession(sessionId: remoteSessionId)

            let session = UseSenseSession(
                config: config,
                sessionType: .authentication,
                eventEmitter: EventEmitter()
            )
            self.session = session

            session.injectHostedSessionData(initResponse.toCreateSessionResponse())

            currentStep = .capture
        } catch {
            errorTitle = "Failed to Start"
            errorMessage = (error as? UseSenseError)?.message ?? error.localizedDescription
            currentStep = .error
        }
    }

    private func handleDispute() async {
        do {
            _ = try await apiClient.disputeRemoteSession(sessionId: remoteSessionId)

            // Show alert per spec
            await MainActor.run {
                let alert = UIAlertController(
                    title: "Report Submitted",
                    message: "Your report has been submitted. All pending actions have been frozen.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.onComplete?(.success("DISPUTED"))
                    self?.dismiss(animated: true)
                })
                self.present(alert, animated: true)
            }
        } catch {
            await MainActor.run {
                let alert = UIAlertController(
                    title: "Error",
                    message: "Failed to submit dispute. Please try again.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func handleCaptureComplete(_ result: Result<RedactedDecisionObject, UseSenseError>) async {
        currentStep = .finalizing
        self.captureDecision = (try? result.get())?.decision

        // Spec safety net: wrap /complete in do-catch, always show result
        do {
            let completeResult = try await apiClient.completeRemoteSession(sessionId: remoteSessionId)
            let finalDecision = completeResult.decision ?? captureDecision ?? "REJECT"
            self.captureDecision = finalDecision
        } catch {
            // STILL show result - never leave user stuck
            if captureDecision == nil || captureDecision == "APPROVE" {
                // If capture said APPROVE but complete failed, still show success
                // (the capture engine already verified the session)
            }
            if captureDecision == nil {
                captureDecision = "REJECT"
            }
        }
        currentStep = .result
    }

    // MARK: - UI Rendering

    private func updateUI() {
        guard isViewLoaded else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isViewLoaded else { return }
                self.renderCurrentStep()
            }
            return
        }
        renderCurrentStep()
    }

    private func renderCurrentStep() {
        let isActionAuth = sessionData?.actionContext?.actionText != nil

        let view: AnyView
        switch currentStep {
        case .loading:
            view = AnyView(HostedLoadingView(branding: branding))

        case .error:
            view = AnyView(HostedErrorView(branding: branding, title: errorTitle, message: errorMessage))

        case .actionReview:
            view = AnyView(ActionReviewView(
                branding: branding,
                actionContext: sessionData?.actionContext,
                onVerify: { [weak self] in
                    Task { await self?.startCapture() }
                },
                onDispute: isActionAuth ? { [weak self] in
                    // Spec: show UIAlertController confirmation first
                    guard let self = self else { return }
                    let alert = UIAlertController(
                        title: "Report This Request",
                        message: "Are you sure this is not your request? This will freeze all pending actions.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(title: "Report", style: .destructive) { _ in
                        Task { await self.handleDispute() }
                    })
                    self.present(alert, animated: true)
                } : nil
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
            view = AnyView(HostedFinalizingView(branding: branding, title: "Processing Verification"))

        case .result:
            let flowType: HostedResultView.HostedFlowType = isActionAuth
                ? .verificationAction : .verificationPlain

            view = AnyView(HostedResultView(
                branding: branding,
                decision: captureDecision ?? "REJECT",
                flowType: flowType,
                actionText: sessionData?.actionContext?.actionText,
                successMessage: sessionData?.successMessage,
                errorMessage: sessionData?.errorMessage,
                reviewMessage: sessionData?.reviewMessage,
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
#endif
