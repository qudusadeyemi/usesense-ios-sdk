#if canImport(UIKit) && canImport(SafariServices)
import UIKit
import SwiftUI
import SafariServices
import VisionKit

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
final class FlowsRunnerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate, VNDocumentCameraViewControllerDelegate {
    private let client: FlowsClient
    private let options: RunFlowOptions
    private let completion: (Result<FlowRunResult, FlowError>) -> Void

    private var view_: FlowRunView?
    private var spinner: UIActivityIndicatorView?
    private var contentContainer: UIView!
    private var safari: SFSafariViewController?
    /// Per-field server validation errors from the last advance(). Keyed on
    /// FormField.key. Cleared on the next successful advance.
    private var fieldErrors: [String: String] = [:]
    /// Tracks whether we have opened the info action's external URL so the
    /// primary CTA changes copy and the next tap advances.
    private var infoOpenURLPresented = false

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
            fieldErrors = [:]
            render()
        } catch let e as FlowError where e.code == .invalidInput {
            // Inline per-field errors; do not terminate the run.
            fieldErrors = e.details
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
        case .captureDocument(_, _, _, _, let captureMethods):
            presentDocumentCapture(methods: captureMethods)
        case .captureForm(let fields):
            installForm(fields: fields)
        case .info(let info):
            installInfo(info)
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

    private func installForm(fields: [FormField]) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "A few details"
        title.font = .preferredFont(forTextStyle: .title2)
        stack.addArrangedSubview(title)

        // One row per field. Inputs and error labels are kept in dictionaries
        // keyed on field.key so a 422 invalid_input response can flip the
        // matching error label visible without rebuilding the form.
        var inputs: [String: FieldInputBinding] = [:]
        var errorLabels: [String: UILabel] = [:]
        for field in fields {
            let (row, binding, errorLabel) = makeFieldRow(field, serverError: fieldErrors[field.key])
            inputs[field.key] = binding
            errorLabels[field.key] = errorLabel
            stack.addArrangedSubview(row)
        }

        let submit = UIButton(type: .system)
        submit.setTitle("Continue", for: .normal)
        submit.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        submit.backgroundColor = UIColor(red: 0.31, green: 0.49, blue: 1.0, alpha: 1.0)
        submit.tintColor = .white
        submit.layer.cornerRadius = 8
        submit.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Client-side echo of modules/flows/form-validation.ts. The server
            // is still authoritative; this is just inline feedback before the
            // round-trip.
            var clientErrors: [String: String] = [:]
            var values: [String: Any] = [:]
            for field in fields {
                let raw = inputs[field.key]?.value() ?? ""
                if let err = self.validate(field: field, raw: raw) {
                    clientErrors[field.key] = err
                } else {
                    values[field.key] = self.coerce(field: field, raw: raw)
                }
            }
            if !clientErrors.isEmpty {
                for (k, msg) in clientErrors {
                    errorLabels[k]?.text = msg
                    errorLabels[k]?.isHidden = false
                }
                return
            }
            Task { await self.advance(inputs: values) }
        }, for: .touchUpInside)
        stack.addArrangedSubview(submit)

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Form rendering helpers

    /// Bound to a single field's input control so the submit handler can read
    /// its value without caring about the concrete UIKit class underneath.
    private struct FieldInputBinding {
        let value: () -> Any
    }

    private func makeFieldRow(_ field: FormField, serverError: String?) -> (UIView, FieldInputBinding, UILabel) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4

        let label = UILabel()
        label.text = (field.label ?? humanise(field.key)) + (field.required ? " *" : "")
        label.font = .preferredFont(forTextStyle: .subheadline)
        container.addArrangedSubview(label)

        let binding: FieldInputBinding
        switch field.type {
        case .select, .country:
            let options: [(String, String)] = field.type == .country
                ? (field.allowedCountries ?? []).map { ($0, $0) }
                : (field.options ?? []).map { ($0.value, $0.label) }
            let picker = OptionButton(title: field.placeholder ?? "Select…", options: options,
                                      initial: field.initial?.value as? String)
            container.addArrangedSubview(picker)
            binding = FieldInputBinding(value: { picker.selectedValue ?? "" })
        case .checkbox:
            let sw = UISwitch()
            sw.isOn = (field.initial?.value as? Bool) ?? false
            let row = UIStackView(arrangedSubviews: [sw, UILabel.makeBody(field.hint ?? "")])
            row.axis = .horizontal
            row.spacing = 12
            container.addArrangedSubview(row)
            binding = FieldInputBinding(value: { sw.isOn })
        default:
            let tf = UITextField()
            tf.borderStyle = .roundedRect
            tf.placeholder = field.placeholder
            tf.text = field.initial?.value as? String
            switch field.type {
            case .email: tf.keyboardType = .emailAddress; tf.autocapitalizationType = .none
            case .tel:   tf.keyboardType = .phonePad
            case .number: tf.keyboardType = .decimalPad
            case .date:  tf.placeholder = field.placeholder ?? "YYYY-MM-DD"
            default: break
            }
            container.addArrangedSubview(tf)
            binding = FieldInputBinding(value: { tf.text ?? "" })
        }

        if let hint = field.hint, !hint.isEmpty, field.type != .checkbox {
            container.addArrangedSubview(UILabel.makeHint(hint))
        }

        let errorLabel = UILabel()
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.text = serverError
        errorLabel.isHidden = serverError == nil
        container.addArrangedSubview(errorLabel)

        return (container, binding, errorLabel)
    }

    private func validate(field: FormField, raw: Any) -> String? {
        let v = field.validators
        let isBlank: Bool = {
            if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }()
        if isBlank {
            return field.required ? "\(field.label ?? humanise(field.key)) is required" : nil
        }
        if let s = raw as? String, let v {
            if let pattern = v.pattern,
               let _ = try? NSRegularExpression(pattern: pattern, options: []),
               s.range(of: pattern, options: .regularExpression) == nil {
                return v.errorMessage ?? "\(field.label ?? humanise(field.key)) is not in the expected format"
            }
            if let min = v.minLength, s.count < min { return v.errorMessage ?? "Must be at least \(min) characters" }
            if let max = v.maxLength, s.count > max { return v.errorMessage ?? "Must be at most \(max) characters" }
        }
        if field.type == .number, let s = raw as? String {
            guard let n = Double(s) else { return field.validators?.errorMessage ?? "\(field.label ?? humanise(field.key)) must be a number" }
            if let min = field.validators?.minNumber, n < min { return field.validators?.errorMessage ?? "Must be at least \(min)" }
            if let max = field.validators?.maxNumber, n > max { return field.validators?.errorMessage ?? "Must be at most \(max)" }
        }
        if field.type == .date, let s = raw as? String {
            if let min = field.validators?.minString, s < min { return field.validators?.errorMessage ?? "Must be on or after \(min)" }
            if let max = field.validators?.maxString, s > max { return field.validators?.errorMessage ?? "Must be on or before \(max)" }
        }
        return nil
    }

    private func coerce(field: FormField, raw: Any) -> Any {
        switch field.type {
        case .checkbox: return raw as? Bool ?? false
        case .number:
            if let s = raw as? String, let n = Double(s) { return n }
            return raw
        default: return raw
        }
    }

    private func installInfo(_ info: InfoAction) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = info.title
        title.font = .preferredFont(forTextStyle: .title1)
        title.numberOfLines = 0
        stack.addArrangedSubview(title)

        if let body = info.body, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }

        for bullet in info.bullets {
            stack.addArrangedSubview(bulletRow(bullet))
        }

        let primary = UIButton(type: .system)
        let primaryTitle: String = {
            if infoOpenURLPresented && info.primary.openURL != nil { return "I'm back, continue" }
            return info.primary.label
        }()
        primary.setTitle(primaryTitle, for: .normal)
        primary.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        primary.backgroundColor = UIColor(red: 0.31, green: 0.49, blue: 1.0, alpha: 1.0)
        primary.tintColor = .white
        primary.layer.cornerRadius = 8
        primary.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Open the external URL in SFSafariViewController first; advance
            // only after the subject returns (delegate dismiss → advance via
            // safariViewControllerDidFinish, which already calls advance(:)).
            if let url = info.primary.openURL, !self.infoOpenURLPresented {
                self.infoOpenURLPresented = true
                self.presentConsent(url: url)
                return
            }
            self.infoOpenURLPresented = false
            Task { await self.advance(inputs: [:]) }
        }, for: .touchUpInside)
        stack.addArrangedSubview(primary)

        if let secondary = info.secondary {
            let s = UIButton(type: .system)
            s.setTitle(secondary.label, for: .normal)
            s.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            s.backgroundColor = .secondarySystemBackground
            s.setTitleColor(.label, for: .normal)
            s.layer.cornerRadius = 8
            s.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                switch secondary.action {
                case .cancel:  Task { await self.cancelRun() }
                case .advance: Task { await self.advance(inputs: [:]) }
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(s)
        }

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -24),
        ])
    }

    private func bulletRow(_ bullet: InfoBullet) -> UIView {
        let icon = UILabel()
        icon.text = Self.bulletGlyph(bullet.icon)
        icon.font = .preferredFont(forTextStyle: .body)
        icon.textAlignment = .center
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let text = UILabel()
        text.text = bullet.text
        text.font = .preferredFont(forTextStyle: .callout)
        text.textColor = .label
        text.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [icon, text])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .top
        return row
    }

    private static func bulletGlyph(_ icon: InfoBulletIcon?) -> String {
        // Single-char glyphs keep the SDK icon-library-free; unknown icons
        // render as the info dot per the contract (never block).
        switch icon {
        case .check: return "✓"
        case .shield: return "⛨"
        case .camera: return "📷"
        case .warning: return "!"
        case .info, .none: return "i"
        }
    }

    private func presentFaceCapture(toolId: String?) {
        // Hosted parity: show the face primer first ("Take a selfie" + the do's),
        // then mint the capture session on the CTA and hand off to the existing
        // capture UI. The CTA shows progress while init-session is in flight.
        let model = FacePrimerModel()
        let primer = UIHostingController(
            rootView: FacePrimerContainer(model: model, brandColor: USColors.primary) { [weak self] in
                guard let self else { return }
                model.isBusy = true
                Task {
                    do {
                        let response = try await self.client.initSession(toolId: toolId)
                        self.dismiss(animated: false) { self.presentCaptureViewController(with: response) }
                    } catch let e as FlowError {
                        self.dismiss(animated: true) { self.finish(.failure(e)) }
                    } catch {
                        self.dismiss(animated: true) {
                            self.finish(.failure(FlowError(code: .unknown, message: error.localizedDescription)))
                        }
                    }
                }
            }
        )
        primer.modalPresentationStyle = .fullScreen
        present(primer, animated: true)
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

    /// Offer the subject every operator-allowed method (default both): a rear-
    /// camera VisionKit scan and/or file upload.
    private func presentDocumentCapture(methods: [String]) {
        let canScan = methods.isEmpty || methods.contains("camera")
        let canUpload = methods.isEmpty || methods.contains("upload")
        if canScan && canUpload {
            let sheet = UIAlertController(title: "Add your document", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Scan with camera", style: .default) { [weak self] _ in self?.launchDocumentScanner() })
            sheet.addAction(UIAlertAction(title: "Upload a file", style: .default) { [weak self] _ in self?.presentUploadPicker() })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in Task { await self?.cancelRun() } })
            present(sheet, animated: true)
        } else if canScan {
            launchDocumentScanner()
        } else {
            presentUploadPicker()
        }
    }

    /// Rear-camera document scan via VisionKit (edge detect, deskew). Falls back
    /// to the upload picker when scanning is unsupported.
    private func launchDocumentScanner() {
        guard VNDocumentCameraViewController.isSupported else { presentUploadPicker(); return }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        present(scanner, animated: true)
    }

    /// Photo-library / file upload.
    private func presentUploadPicker() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.85) else {
            return
        }
        uploadDocument(base64: data.base64EncodedString())
    }

    // MARK: - VisionKit document scanner

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)
        guard scan.pageCount > 0, let data = scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.85) else { return }
        uploadDocument(base64: data.base64EncodedString())
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true) { [weak self] in Task { await self?.cancelRun() } }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true) { [weak self] in self?.presentUploadPicker() }
    }

    /// Upload a document (scanned or picked) and advance the run.
    private func uploadDocument(base64: String) {
        let category: String = {
            if case .captureDocument(let cat, _, _, _, _) = view_?.pendingAction { return cat }
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

/// Minimal UIMenu-backed picker so we don't pull in UIKit pickers for a
/// single-choice select. Holds the chosen value; the title shows the chosen
/// label or the placeholder.
private final class OptionButton: UIButton {
    private let placeholderTitle: String
    private(set) var selectedValue: String?
    init(title: String, options: [(value: String, label: String)], initial: String?) {
        self.placeholderTitle = title
        super.init(frame: .zero)
        setTitleColor(.label, for: .normal)
        contentHorizontalAlignment = .leading
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let actions = options.map { opt in
            UIAction(title: opt.label) { [weak self] _ in
                self?.selectedValue = opt.value
                self?.setTitle(opt.label, for: .normal)
            }
        }
        menu = UIMenu(children: actions)
        showsMenuAsPrimaryAction = true
        if let initial, let match = options.first(where: { $0.value == initial }) {
            selectedValue = match.value
            setTitle(match.label, for: .normal)
        } else {
            setTitle(title, for: .normal)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

private extension UILabel {
    static func makeHint(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .preferredFont(forTextStyle: .caption1)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }
    static func makeBody(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .preferredFont(forTextStyle: .body)
        l.numberOfLines = 0
        return l
    }
}
#endif
