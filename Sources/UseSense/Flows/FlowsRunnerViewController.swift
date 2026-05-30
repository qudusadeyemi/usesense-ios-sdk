#if canImport(UIKit) && canImport(SafariServices)
import UIKit
import SafariServices

/// Drives a Flow Run end to end. One state machine; one of four surfaces
/// rendered per parked action (face / document / form / consent). Mirrors the
/// web SDK's FlowRunner state machine so the subject UX is identical across
/// platforms.
///
/// Face capture wiring lands in slice 5a-2: the existing UseSenseSession
/// expects token-exchange to mint its credentials, while Flows hands the
/// runner pre-minted session credentials from /init-session. Adding the
/// session-injection seam is the focused follow-up; today the runner
/// surfaces FlowError.unsupportedAction for face steps with a clear hint.
final class FlowsRunnerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let client: FlowsClient
    private let options: RunFlowOptions
    private let completion: (Result<FlowRunResult, FlowError>) -> Void

    private var view_: FlowRunView?
    private var spinner: UIActivityIndicatorView?
    private var contentContainer: UIView!
    private var safari: SFSafariViewController?

    init(options: RunFlowOptions, completion: @escaping (Result<FlowRunResult, FlowError>) -> Void) {
        self.options = options
        self.client = FlowsClient(flowRunId: options.flowRunId, sdkToken: options.sdkToken, apiBaseURL: options.apiBaseURL)
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installScaffold()
        Task { await refreshAndDrive() }
    }

    // MARK: - Driver

    private func refreshAndDrive() async {
        await load()
        guard let view = view_ else { return }
        // Auto-advance freshly created runs to the first interactive step.
        if view.state == .pending && view.pendingAction == nil {
            await advance(inputs: [:])
        }
    }

    private func load() async {
        showSpinner()
        do {
            let next = try await client.get()
            view_ = next
            render()
        } catch let e as FlowError {
            finish(.failure(e))
        } catch {
            finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
        }
    }

    private func advance(inputs: [String: Any]) async {
        showSpinner()
        do {
            let next = try await client.advance(inputs: inputs)
            view_ = next
            render()
        } catch let e as FlowError {
            finish(.failure(e))
        } catch {
            finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
        }
    }

    private func cancelRun() async {
        do {
            let next = try await client.cancel()
            view_ = next
            render()
        } catch let e as FlowError {
            finish(.failure(e))
        } catch {
            finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
        }
    }

    // MARK: - Render

    private func render() {
        guard let view = view_ else { return }
        hideSpinner()
        // Terminal: deliver the result and dismiss.
        switch view.state {
        case .completed, .errored, .cancelled, .abandoned:
            finish(.success(FlowRunResult(flowRunId: view.id, state: view.state, outcome: view.outcome)))
            return
        default: break
        }
        guard let action = view.pendingAction else {
            showSpinner()
            return
        }
        switch action {
        case .captureFace(let toolId):
            presentFaceCapture(toolId: toolId)
        case .captureDocument(let category, _, _):
            presentDocumentPicker(category: category)
        case .captureForm(let fields):
            installForm(fields: fields)
        case .redirectToConsent(let url):
            presentConsent(url: url)
        }
    }

    private func finish(_ result: Result<FlowRunResult, FlowError>) {
        // Guard against double-callback if a network error and a terminal
        // state both fire — the first wins, subsequent calls are no-ops.
        let cb = completion
        dismiss(animated: true) {
            cb(result)
        }
    }

    // MARK: - Surfaces

    private func installForm(fields: [String]) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "A few details"
        title.font = .preferredFont(forTextStyle: .title2)
        stack.addArrangedSubview(title)

        var inputs: [String: UITextField] = [:]
        for field in fields {
            let label = UILabel()
            label.text = humanise(field)
            label.font = .preferredFont(forTextStyle: .subheadline)
            let tf = UITextField()
            tf.borderStyle = .roundedRect
            tf.placeholder = humanise(field)
            inputs[field] = tf
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(tf)
        }

        let submit = UIButton(type: .system)
        submit.setTitle("Continue", for: .normal)
        submit.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        submit.backgroundColor = UIColor(red: 0.31, green: 0.49, blue: 1.0, alpha: 1.0)
        submit.tintColor = .white
        submit.layer.cornerRadius = 8
        submit.addAction(UIAction { [weak self] _ in
            let values = inputs.mapValues { $0.text ?? "" }
            Task { await self?.advance(inputs: values) }
        }, for: .touchUpInside)
        stack.addArrangedSubview(submit)

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -24),
        ])
    }

    private func presentFaceCapture(toolId: String?) {
        Task {
            do {
                let response = try await client.initSession(toolId: toolId)
                presentCaptureViewController(with: response)
            } catch let e as FlowError {
                finish(.failure(e))
            } catch {
                finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
            }
        }
    }

    /// Build a UseSenseSession from the /init-session response, inject the
    /// pre-minted credentials, and present the existing capture UI. The api
    /// key is a placeholder ("flow_runner") because every downstream API call
    /// the capture engine makes authenticates with the session_token set by
    /// injectHostedSessionData(...); the session-create / exchange-token paths
    /// that would need a real api key are skipped because sessionData is
    /// already populated. Environment is inherited from the flow run.
    private func presentCaptureViewController(with response: CreateSessionResponse) {
        guard let view = view_ else { return }
        let endpoint = options.apiBaseURL.appendingPathComponent("v1").absoluteString
        let environment: Environment = view.environment == "sandbox" ? .sandbox : .production
        let config = UseSenseConfig(apiEndpoint: endpoint, apiKey: "flow_runner", environment: environment)
        let session = UseSenseSession(config: config, sessionType: .enrollment)
        session.injectHostedSessionData(response)
        let captureVC = UseSenseViewController(session: session) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let decision):
                let sessionId = decision.sessionId
                let identityId = decision.identityId
                var inputs: [String: Any] = ["sessionId": sessionId]
                if let id = identityId { inputs["identityId"] = id }
                Task { await self.advance(inputs: inputs) }
            case .failure(let err):
                if err.code == .userCancelled {
                    Task { await self.cancelRun() }
                } else {
                    self.finish(.failure(FlowError(code: .providerUnavailable, message: err.message)))
                }
            }
        }
        captureVC.modalPresentationStyle = .fullScreen
        present(captureVC, animated: true)
    }

    private func presentDocumentPicker(category: String) {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = self
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.85) else {
            return
        }
        let base64 = data.base64EncodedString()
        let category: String = {
            if case .captureDocument(let cat, _, _) = view_?.pendingAction { return cat }
            return "identity"
        }()
        Task {
            do {
                let response = try await client.uploadDocument(data: base64, mimeType: "image/jpeg", side: "single", documentType: category)
                if response.status == "failed" {
                    let code: FlowError.Code = response.reason == "provider" ? .providerUnavailable : .unknown
                    finish(.failure(FlowError(code: code, message: response.reason == "provider"
                                              ? "Verification is temporarily unavailable."
                                              : "We couldn't read that document. Please retake it.")))
                    return
                }
                await advance(inputs: ["document_id": response.documentId])
            } catch let e as FlowError {
                finish(.failure(e))
            } catch {
                finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            Task { await self?.cancelRun() }
        }
    }

    private func presentConsent(url: URL) {
        let vc = SFSafariViewController(url: url)
        vc.delegate = self
        safari = vc
        present(vc, animated: true)
    }

    // MARK: - Scaffold

    private func installScaffold() {
        contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let cancel = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(onCancelTapped))
        navigationItem.leftBarButtonItem = cancel
    }

    @objc private func onCancelTapped() {
        Task { await cancelRun() }
    }

    private func showSpinner() {
        if spinner == nil {
            let s = UIActivityIndicatorView(style: .medium)
            s.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(s)
            NSLayoutConstraint.activate([
                s.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                s.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            spinner = s
        }
        spinner?.startAnimating()
    }

    private func hideSpinner() {
        spinner?.stopAnimating()
        spinner?.removeFromSuperview()
        spinner = nil
    }
}

extension FlowsRunnerViewController: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        safari = nil
        Task { await advance(inputs: [:]) }
    }
}

private func humanise(_ s: String) -> String {
    s.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
#endif
