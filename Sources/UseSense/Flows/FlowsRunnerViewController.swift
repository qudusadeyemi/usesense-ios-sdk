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
    /// Branded loader (FlowLoadingView) hosted over the runner: between steps and
    /// during document upload. Typed so its message can be updated in place.
    private var loadingHost: UIHostingController<FlowLoadingView>?
    private var contentContainer: UIView!
    private var safari: SFSafariViewController?
    /// Per-field server validation errors from the last advance(). Keyed on
    /// FormField.key. Cleared on the next successful advance.
    private var fieldErrors: [String: String] = [:]
    /// Tracks whether we have opened the info action's external URL so the
    /// primary CTA changes copy and the next tap advances.
    private var infoOpenURLPresented = false
    /// The branded form surface, while a captureForm step is on screen. Reused
    /// across server invalid_input re-renders so the subject's input is preserved.
    private var formModel: FormModel?
    /// Location capture state. Held on the controller rather than in the form
    /// model so the position and the descriptors stay separable: they are
    /// different evidence classes and the scorer weighs them apart.
    private var locationSpec: LocationCaptureSpec?
    private var locationFix: LocationFix?
    #if canImport(CoreLocation)
    private var locationFixer: LocationFixer?
    #endif
    private weak var formHost: UIViewController?
    /// Guards re-presenting the id_number surface on a re-render.
    private var idNumberPresented = false
    /// Guards re-presenting the terminal result surface on a re-render.
    private var resultPresented = false

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
        // Seed the appearance + copy resolvers with the SDK-init layer immediately
        // so the first loading surface is already themed and worded; the server
        // layer is merged in once the run loads (see applyResolved*).
        applyResolvedAppearance(server: nil)
        applyResolvedCopy(server: nil)
        view.backgroundColor = .systemBackground
        installScaffold()
        Task { await refreshAndDrive() }
    }

    /// Merge the SDK-init appearance (options.appearance, highest priority) over
    /// the server-delivered branding.appearance, with the server's flat
    /// `branding.primary_color` folded in as the lowest-priority colour, and
    /// publish the result to the resolver, which re-themes USColors / the brand
    /// font ramp / button shape for every surface. Also forces the runner's
    /// interface style when the appearance pins `mode` to light or dark.
    ///
    /// Precedence (mirrors web FlowRunner.tsx + Android FlowsActivity.mergedAppearance):
    ///   SDK-init appearance
    ///     > server appearance (branding.appearance)
    ///       > server flat primary_color (branding.primary_color)
    ///         > built-in default
    /// The flat colour is GUARDED: it only folds in when neither the SDK-init
    /// layer nor the server appearance already set `colors.primary`, so an
    /// operator who configures a full appearance keeps that exact palette.
    private func applyResolvedAppearance(server: FlowAppearance?) {
        // Lowest-priority colour layer from the server's flat primary_color.
        // Web guards on `branding.primary_color` being truthy; on iOS the field
        // is non-optional and defaults to the built-in `#4F7CFF`, so folding the
        // default is a no-op anyway. The load-bearing guard is the one matching
        // web/Android: only apply when no higher layer pinned `colors.primary`.
        let legacyServerColor: FlowAppearance? = {
            guard options.appearance?.colors?.primary == nil,
                  server?.colors?.primary == nil,
                  let flat = view_?.branding?.primaryColor,
                  !flat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return FlowAppearance(colors: AppearanceColors(primary: flat))
        }()
        let serverLayer = FlowAppearance.merge(high: server, low: legacyServerColor)
        let merged = FlowAppearance.merge(high: options.appearance, low: serverLayer)
        FlowAppearanceResolver.set(merged)
        switch merged?.mode ?? .auto {
        case .light: overrideUserInterfaceStyle = .light
        case .dark:  overrideUserInterfaceStyle = .dark
        case .auto:  overrideUserInterfaceStyle = .unspecified
        }
    }

    /// Merge the SDK-init copy (options.copy, highest priority) over the
    /// server-delivered branding.copy and publish it to the resolver, which the
    /// parity screens read for every subject-facing string. Mirrors
    /// applyResolvedAppearance; presentation only.
    private func applyResolvedCopy(server: FlowCopy?) {
        let merged = FlowCopy.merge(high: options.copy, low: server)
        FlowCopyResolver.set(merged)
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
            applyResolvedAppearance(server: next.branding?.appearance)
            applyResolvedCopy(server: next.branding?.copy)
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
            applyResolvedAppearance(server: next.branding?.appearance)
            applyResolvedCopy(server: next.branding?.copy)
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
        // Terminal: show the branded result screen, then deliver the result when
        // the subject taps Continue. Subject-initiated exits (cancel / abandon)
        // close immediately with no result screen.
        switch view.state {
        case .cancelled, .abandoned:
            finish(.success(FlowRunResult(flowRunId: view.id, state: view.state, outcome: view.outcome)))
            return
        case .completed, .errored:
            presentResult(for: view)
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
        case .captureDocument(let category, let documentTypes, let issuingCountries, let camera, let captureMethods):
            presentDocumentFlow(
                category: category,
                documentTypes: documentTypes,
                issuingCountries: issuingCountries,
                camera: camera,
                methods: captureMethods
            )
        case .captureForm(let fields):
            presentForm(fields: fields)
        case .captureLocation(let spec):
            presentLocation(spec: spec)
        case .captureIdNumber(let idTypes):
            presentIdNumber(idTypes: idTypes)
        case .info(let info):
            installInfo(info)
        case .redirectToConsent(let url):
            presentConsent(url: url)
        }
    }

    /// Presents the branded terminal result screen (success / under review /
    /// not verified) mapped from the run outcome, and reports the result only
    /// once the subject taps Continue — mirroring the hosted run page.
    private func presentResult(for view: FlowRunView) {
        if resultPresented { return }
        resultPresented = true
        let kind: FlowResultView.Kind
        switch view.outcome {
        case .approve:      kind = .success
        case .reject:       kind = .notVerified
        case .manualReview: kind = .review
        case .none:         kind = view.state == .errored ? .notVerified : .success
        }
        let result = FlowRunResult(flowRunId: view.id, state: view.state, outcome: view.outcome)
        let doneTitle = FlowCopyResolver.text(\.buttons?.continue, default: "Done")
        let host = UIHostingController(rootView: FlowResultView(kind: kind, continueTitle: doneTitle, onContinue: { [weak self] in
            guard let self else { return }
            // Tear down the result surface, then the runner, then report.
            self.dismiss(animated: true) { self.finish(.success(result)) }
        }, branding: brandingHeader))
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    private func finish(_ result: Result<FlowRunResult, FlowError>) {
        // Guard against double-callback if a network error and a terminal
        // state both fire — the first wins, subsequent calls are no-ops.
        let cb = completion
        // Clear the per-run appearance + copy so a subsequent run (or any other
        // SDK surface) starts from the built-in tokens / copy rather than this
        // run's theme.
        FlowAppearanceResolver.reset()
        FlowCopyResolver.reset()
        dismiss(animated: true) {
            cb(result)
        }
    }

    /// The org lockup shown at the top of each surface, honouring the resolved
    /// appearance: the logo URL (appearance.logo.url, else server branding) and
    /// placement (`none` suppresses the header). Returns nil when there is no
    /// branding to show or placement is `none`.
    private var brandingHeader: USBrandingHeader? {
        let placement = FlowAppearanceResolver.logoPlacement
        if placement == AppearanceLogo.Placement.none { return nil }
        let logoURL = FlowAppearanceResolver.logoURL ?? view_?.branding?.logoURL
        let displayName = view_?.branding?.displayName
        if logoURL == nil && displayName == nil { return nil }
        return USBrandingHeader(displayName: displayName, logoURL: logoURL)
    }

    // MARK: - Surfaces

    // MARK: - ID number surface (branded)

    private func presentIdNumber(idTypes: [IdTypeSpec]) {
        // Avoid re-presenting on a re-render; the modal stays until submit.
        if idNumberPresented { return }
        idNumberPresented = true
        let options = idTypes.map {
            IdTypeOption(value: $0.value, label: $0.label, hint: $0.hint, field: $0.field, maxLength: $0.maxLength, numeric: $0.numeric)
        }
        let host = UIHostingController(rootView: IdNumberView(idTypes: options, brandColor: USColors.primary, branding: brandingHeader) { [weak self] idType, field, value in
            guard let self else { return }
            self.idNumberPresented = false
            // Mirror the hosted page: advance({ id_type, [field]: value }).
            self.dismiss(animated: false) {
                Task { await self.advance(inputs: ["id_type": idType, field: value]) }
            }
        })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    // MARK: - Location surface (address ladder rung 0)

    /// Presents the descriptor form and acquires a position alongside it.
    ///
    /// The two run concurrently on purpose. Making the subject watch a spinner
    /// while CoreLocation settles wastes the time they could spend typing, and
    /// the position is not required to continue: this surface never terminates
    /// the step in failure. A denied permission, Location Services switched
    /// off, or a fix that never arrives all still submit the descriptors and
    /// advance, at a lower rung, because a low-confidence record that can be
    /// upgraded is worth more than an abandoned onboarding.
    private func presentLocation(spec: LocationCaptureSpec) {
        if let model = formModel {
            model.errors = fieldErrors
            model.isBusy = false
            return
        }
        locationSpec = spec
        locationFix = nil

        let model = FormModel(fields: spec.descriptorFields, serverErrors: fieldErrors)
        model.statusLine = LocationCapture.statusText(for: .acquiring)
        formModel = model

        let host = UIHostingController(rootView: FormScreen(model: model, brandColor: USColors.primary, branding: brandingHeader) { [weak self] in
            self?.submitLocation()
        })
        host.modalPresentationStyle = .fullScreen
        formHost = host
        present(host, animated: true)

        #if canImport(CoreLocation)
        let fixer = LocationFixer()
        locationFixer = fixer
        fixer.start(timeoutMs: spec.maxWaitMs) { [weak self] fix, state in
            guard let self else { return }
            self.locationFix = fix
            self.formModel?.statusLine = LocationCapture.statusText(for: state, accuracyM: fix?.accuracyM)
            self.formModel?.statusIsGood = (state == .ready)
        }
        #else
        model.statusLine = LocationCapture.statusText(for: .unavailable)
        #endif
    }

    private func submitLocation() {
        guard let model = formModel, let spec = locationSpec else { return }
        var clientErrors: [String: String] = [:]
        var descriptors: [String: Any] = [:]
        for field in model.fields {
            let raw = model.rawValue(for: field)
            if let err = validate(field: field, raw: raw) {
                clientErrors[field.key] = err
            } else {
                descriptors[field.key] = coerce(field: field, raw: raw)
            }
        }
        if !clientErrors.isEmpty {
            model.errors = clientErrors
            return
        }
        model.errors = [:]
        model.isBusy = true

        // Whatever the position state is at this moment is what we send. We do
        // not wait for a pending fix: the subject has decided they are ready,
        // and holding them for CoreLocation would be the blocking behaviour
        // this surface exists to avoid. A fix that arrives later simply misses
        // this submit, and the record can be upgraded afterwards.
        let inputs = LocationCapture.buildInputs(
            fix: locationFix,
            descriptors: descriptors,
            requestedRung: spec.rung
        )

        Task {
            await advance(inputs: inputs)
            if let action = view_?.pendingAction, case .captureLocation = action {
                model.isBusy = false
            } else {
                #if canImport(CoreLocation)
                locationFixer?.cancel()
                locationFixer = nil
                #endif
                locationSpec = nil
                locationFix = nil
                dismissForm()
            }
        }
    }

    // MARK: - Form surface (branded)

    private func presentForm(fields: [FormField]) {
        // Re-render after a server invalid_input: refresh the existing form's
        // errors instead of re-presenting (keeps the subject's input).
        if let model = formModel {
            model.errors = fieldErrors
            model.isBusy = false
            return
        }
        let model = FormModel(fields: fields, serverErrors: fieldErrors)
        formModel = model
        let host = UIHostingController(rootView: FormScreen(model: model, brandColor: USColors.primary, branding: brandingHeader) { [weak self] in
            self?.submitForm()
        })
        host.modalPresentationStyle = .fullScreen
        formHost = host
        present(host, animated: true)
    }

    private func submitForm() {
        guard let model = formModel else { return }
        // Client-side echo of the server validation; the server stays authoritative.
        var clientErrors: [String: String] = [:]
        var values: [String: Any] = [:]
        for field in model.fields {
            let raw = model.rawValue(for: field)
            if let err = validate(field: field, raw: raw) {
                clientErrors[field.key] = err
            } else {
                values[field.key] = coerce(field: field, raw: raw)
            }
        }
        if !clientErrors.isEmpty {
            model.errors = clientErrors
            return
        }
        model.errors = [:]
        model.isBusy = true
        Task {
            await advance(inputs: values)
            // If still parked on a form, the server rejected the input (errors are
            // refreshed via presentForm's guard); otherwise the run moved on, so
            // tear the form down to reveal the next surface.
            if let action = view_?.pendingAction, case .captureForm = action {
                model.isBusy = false
            } else {
                dismissForm()
            }
        }
    }

    private func dismissForm() {
        formModel = nil
        formHost?.dismiss(animated: true)
        formHost = nil
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
        var primaryConfig = UIButton.Configuration.filled()
        primaryConfig.title = primaryTitle
        primaryConfig.baseBackgroundColor = UIColor(red: 0.31, green: 0.49, blue: 1.0, alpha: 1.0)
        primaryConfig.baseForegroundColor = .white
        primaryConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        primaryConfig.background.cornerRadius = 8
        primary.configuration = primaryConfig
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
            var sConfig = UIButton.Configuration.filled()
            sConfig.title = secondary.label
            sConfig.baseBackgroundColor = .secondarySystemBackground
            sConfig.baseForegroundColor = .label
            sConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            sConfig.background.cornerRadius = 8
            s.configuration = sConfig
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
            rootView: FacePrimerContainer(model: model, brandColor: USColors.primary, branding: brandingHeader) { [weak self] in
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
        // Hand the resolved white-label down with the config. The runner's own
        // surfaces read FlowAppearanceResolver, which applyResolvedAppearance
        // has already seeded -- but the capture screens are a separate
        // presentation that colours from the flat `branding.primaryColor`
        // (EnrollmentIntroductionView and friends), and it was being handed
        // none. The subject saw the org's colour on the step primer and the
        // built-in default on the consent/loading/capture screens either side.
        // Android had the identical gap; keep the two in step.
        let resolved = FlowAppearanceResolver.current
        let config = UseSenseConfig(
            apiEndpoint: endpoint,
            apiKey: "flow_runner",
            environment: environment,
            branding: BrandingConfig(
                primaryColor: resolved?.colors?.primary,
                appearance: resolved,
                copy: FlowCopyResolver.current
            )
        )
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

    /// Hosted parity: the operator-allowed methods are offered through the
    /// branded document primer (and a type chooser when there are multiple types),
    /// then the existing VisionKit scan / file upload. The primer's CTAs are the
    /// method choice ("Take a photo" / "Upload a file instead"), replacing the
    /// plain action sheet.
    private func presentDocumentFlow(
        category: String,
        documentTypes: [String],
        issuingCountries: [String],
        camera: String?,
        methods: [String]
    ) {
        let canScan = methods.isEmpty || methods.contains("camera")
        let canUpload = methods.isEmpty || methods.contains("upload")

        func showPrimer(docType: String?) {
            let host = UIHostingController(rootView: DocumentPrimerView(
                documentType: docType,
                categoryLabel: Self.documentCategoryLabel(category),
                issuingCountries: issuingCountries,
                allowCamera: canScan,
                allowUpload: canUpload,
                brandColor: USColors.primary,
                branding: brandingHeader,
                onPrimary: { [weak self] in
                    self?.dismiss(animated: true) {
                        if canScan { self?.launchDocumentScanner() } else { self?.presentUploadPicker() }
                    }
                },
                onSecondary: (canScan && canUpload) ? { [weak self] in
                    self?.dismiss(animated: true) { self?.presentUploadPicker() }
                } : nil
            ))
            host.modalPresentationStyle = .fullScreen
            present(host, animated: true)
        }

        if !documentTypes.isEmpty {
            let typeHost = UIHostingController(rootView: DocumentTypeSelectView(
                documentTypes: documentTypes,
                brandColor: USColors.primary,
                branding: brandingHeader,
                onContinue: { [weak self] selected in
                    self?.dismiss(animated: false) { showPrimer(docType: selected) }
                }
            ))
            typeHost.modalPresentationStyle = .fullScreen
            present(typeHost, animated: true)
        } else {
            showPrimer(docType: nil)
        }
    }

    /// Friendly category label matching the hosted page's map.
    private static func documentCategoryLabel(_ category: String) -> String {
        switch category {
        case "identity": return "identity document"
        case "proof_of_address": return "proof of address"
        case "organisation_doc": return "organisation document"
        case "tax_doc": return "tax document"
        case "invoice": return "invoice"
        default: return "document"
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
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let image else { return }
            self.presentDocumentConfirm(image: image, captureMethod: "upload") { [weak self] in self?.presentUploadPicker() }
        }
    }

    // MARK: - VisionKit document scanner

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let image = scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil
        controller.dismiss(animated: true) { [weak self] in
            guard let self, let image else { return }
            self.presentDocumentConfirm(image: image, captureMethod: "camera") { [weak self] in self?.launchDocumentScanner() }
        }
    }

    /// Largest decoded upload the documents endpoint accepts (5MB). Encoding
    /// targets a margin below it so the multipart/JSON envelope cannot tip a
    /// borderline capture over the edge.
    private static let documentUploadByteLimit = 5 * 1024 * 1024
    private static let documentUploadByteTarget = 4 * 1024 * 1024

    /// Longest edge kept for an uploaded document. Modern iPhone captures run
    /// 4000px+, which costs upload seconds on a mobile network without helping
    /// OCR: 2000px comfortably resolves MRZ and licence text.
    private static let documentMaxEdge: CGFloat = 2000

    /// JPEG-encode a captured document small enough for the endpoint to accept.
    ///
    /// A full-resolution VisionKit scan at quality 0.85 can exceed 5MB and be
    /// rejected outright (`payload_too_large`), which the subject experiences as
    /// an unexplained failure after they have already done the work. Downscale
    /// first, then step quality down until it fits.
    private static func encodeDocumentForUpload(_ image: UIImage) -> String? {
        let scaled = downscale(image, maxEdge: documentMaxEdge)
        for quality in [CGFloat(0.85), 0.7, 0.55, 0.4] {
            guard let data = scaled.jpegData(compressionQuality: quality) else { continue }
            if data.count <= documentUploadByteTarget {
                return data.base64EncodedString()
            }
        }
        // Last resort: accept anything under the hard limit rather than fail.
        guard let fallback = scaled.jpegData(compressionQuality: 0.3),
              fallback.count <= documentUploadByteLimit else { return nil }
        return fallback.base64EncodedString()
    }

    /// Aspect-preserving downscale. Returns the original when already smaller,
    /// so an upload picked from a low-resolution file is never upscaled.
    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Hosted parity: confirm the captured document (preview + Use / Retake)
    /// before uploading.
    private func presentDocumentConfirm(image: UIImage, captureMethod: String, retake: @escaping () -> Void) {
        let host = UIHostingController(rootView: DocumentConfirmView(
            image: image,
            brandColor: USColors.primary,
            branding: brandingHeader,
            onUse: { [weak self] in
                self?.dismiss(animated: false) {
                    guard let base64 = Self.encodeDocumentForUpload(image) else {
                        // Encoding cannot fail for a real capture, but uploading
                        // "" would have the server reject an empty document and
                        // read to the subject as a mysterious rejection.
                        self?.presentDocumentRetry(
                            message: FlowCopyResolver.text(
                                \.errors?.documentUnreadable,
                                default: "We couldn't read that document. Please retake it."
                            )
                        )
                        return
                    }
                    self?.uploadDocument(base64: base64, captureMethod: captureMethod)
                }
            },
            onRetake: { [weak self] in self?.dismiss(animated: true) { retake() } },
            onUploadInstead: { [weak self] in self?.dismiss(animated: true) { self?.presentUploadPicker() } }
        ))
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        // As with the photo picker: dismissing the scanner means "not this way",
        // not "abandon the verification". Fall back to the document primer so
        // the subject can pick the other capture method or try the scan again.
        controller.dismiss(animated: true) { [weak self] in self?.restartDocumentCapture() }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true) { [weak self] in self?.presentUploadPicker() }
    }

    /// Upload a document (scanned or picked) and advance the run.
    private func uploadDocument(base64: String, captureMethod: String) {
        let category: String = {
            if case .captureDocument(let cat, _, _, _, _) = view_?.pendingAction { return cat }
            return "identity"
        }()
        // The confirm sheet has been dismissed; show the branded loader so the
        // subject sees upload progress instead of a blank runner (mirrors the
        // hosted page's "Submitting your document…").
        showSpinner(message: FlowCopyResolver.text(\.loading?.submittingDocument, default: "Submitting your document…"))
        Task {
            do {
                let response = try await client.uploadDocument(data: base64, mimeType: "image/jpeg", side: "single", documentType: category, captureMethod: captureMethod)
                if response.status == "failed" {
                    // Recoverable by definition: the subject still holds the
                    // document. Tearing the runner down here (as this used to)
                    // ejected them mid-flow with a half-finished run, and the
                    // host app's only move was to cancel and start over, which
                    // is what turned an upstream OCR timeout into an abandoned
                    // verification. Offer a retake inside the flow instead.
                    // 'incomplete' is neither branch: the bytes arrived cut
                    // short, so nothing upstream is wrong and the photo was
                    // never the problem. Sending the same file again is the
                    // remedy; a retake is not. Before this existed the case
                    // arrived as 'provider' and told the subject to wait out an
                    // outage that was not happening.
                    let message: String
                    switch response.reason {
                    case "provider":
                        message = FlowCopyResolver.text(\.errors?.providerUnavailable, default: "Verification is temporarily unavailable.")
                    case "incomplete":
                        message = response.message ?? FlowCopyResolver.text(
                            \.errors?.documentIncomplete,
                            default: "That image did not upload completely. Check your connection and send it again."
                        )
                    case "too_large":
                        message = response.message ?? FlowCopyResolver.text(
                            \.errors?.documentUnreadable,
                            default: "That image is too large. Please use a smaller file."
                        )
                    default:
                        message = FlowCopyResolver.text(\.errors?.documentUnreadable, default: "We couldn't read that document. Please retake it.")
                    }
                    presentDocumentRetry(message: message)
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
        // Backing out of the OS photo picker is a change of mind about *how* to
        // supply the document, not about the verification. Returning to the
        // document primer keeps the run alive; cancelling it here used to make
        // a single mis-tap unrecoverable, and the restart then risked being
        // rejected as a duplicate of the subject's own abandoned attempt.
        picker.dismiss(animated: true) { [weak self] in
            self?.restartDocumentCapture()
        }
    }

    /// Re-present the document step from its current pending action. Used when
    /// a capture surface is dismissed or an upload fails: the step is still
    /// parked server-side, so the subject can simply try again.
    private func restartDocumentCapture() {
        guard case .captureDocument(let category, let documentTypes, let issuingCountries, let camera, let methods) = view_?.pendingAction else {
            // The step moved on underneath us (or the run ended); re-render
            // against whatever the server now says rather than guessing.
            render()
            return
        }
        presentDocumentFlow(
            category: category,
            documentTypes: documentTypes,
            issuingCountries: issuingCountries,
            camera: camera,
            methods: methods
        )
    }

    /// Branded, in-flow document failure with a retake CTA. Keeps the run open
    /// so an upstream extraction failure costs the subject one retry rather
    /// than the whole verification.
    private func presentDocumentRetry(message: String) {
        let host = UIHostingController(rootView: FlowErrorView(
            title: FlowCopyResolver.text(\.errors?.generic, default: "Try that again"),
            message: message,
            retryTitle: FlowCopyResolver.text(\.buttons?.retake, default: "Retake"),
            onRetry: { [weak self] in
                self?.dismiss(animated: true) { self?.restartDocumentCapture() }
            },
            branding: brandingHeader
        ))
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
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
        let cancelTitle = FlowCopyResolver.text(\.buttons?.cancel, default: "Cancel")
        let cancel = UIBarButtonItem(title: cancelTitle, style: .plain, target: self, action: #selector(onCancelTapped))
        navigationItem.leftBarButtonItem = cancel
    }

    @objc private func onCancelTapped() {
        Task { await cancelRun() }
    }

    private func showSpinner(message: String? = nil) {
        let message = message ?? FlowCopyResolver.text(\.loading?.default, default: "Loading")
        // Already showing: just update the message (e.g. "Loading" -> "Submitting
        // your document…") instead of stacking a second loader.
        if let host = loadingHost {
            host.rootView = FlowLoadingView(title: message)
            return
        }
        let host = UIHostingController(rootView: FlowLoadingView(title: message))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        loadingHost = host
    }

    private func hideSpinner() {
        guard let host = loadingHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        loadingHost = nil
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
