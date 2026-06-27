import Foundation

// MARK: - FlowCopy: the white-label copy/messaging override contract (Phase 2)
//
// FlowCopy is the single copy-override schema shared across surfaces and SDKs.
// It mirrors the web SDK contract in packages/sdk/src/flows/copy.ts. Like
// FlowAppearance it can be supplied two ways and is merged
//   SDK-init > server(branding.copy) > built-in default
//   - by the developer at SDK init (`BrandingConfig.copy` / `RunFlowOptions.copy`), and/or
//   - by the operator in the dashboard, delivered in the branding payload.
// Every field is optional; anything omitted keeps the built-in hosted-page copy
// already encoded in the parity screens.

/// The white-label copy override contract. Mirror of the web SDK `FlowCopy`.
public struct FlowCopy: Codable, Equatable, Sendable {
    /// Optional welcome/intro shown before the first step (when set). The iOS
    /// runner has no welcome surface today, so these decode but are unused.
    public var welcome: Welcome?
    /// Shared button labels.
    public var buttons: Buttons?
    /// Titles shown under the loader for each transient state.
    public var loading: Loading?
    /// Face capture primer.
    public var face: Face?
    /// Document capture surfaces.
    public var document: Document?
    /// Form surface.
    public var form: Form?
    /// ID-number surface.
    public var idNumber: IdNumber?
    /// Terminal result screens.
    public var result: Result?
    /// Error copy (provider failure vs unreadable capture vs generic).
    public var errors: Errors?
    /// Privacy / consent disclosures. The iOS runner has no privacy surface
    /// today, so these decode but are unused.
    public var privacy: Privacy?
    /// Free-form help text / tooltips keyed by an SDK-defined slot id.
    public var help: [String: String]?

    public struct Welcome: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public init(title: String? = nil, body: String? = nil) {
            self.title = title; self.body = body
        }
    }

    public struct Buttons: Codable, Equatable, Sendable {
        public var `continue`: String?
        public var cancel: String?
        public var tryAgain: String?
        public var retake: String?
        public var useThisPhoto: String?
        public var uploadInstead: String?
        public var scan: String?
        public var upload: String?
        public var submitting: String?
        public init(
            continue continueLabel: String? = nil, cancel: String? = nil, tryAgain: String? = nil,
            retake: String? = nil, useThisPhoto: String? = nil, uploadInstead: String? = nil,
            scan: String? = nil, upload: String? = nil, submitting: String? = nil
        ) {
            self.continue = continueLabel; self.cancel = cancel; self.tryAgain = tryAgain
            self.retake = retake; self.useThisPhoto = useThisPhoto; self.uploadInstead = uploadInstead
            self.scan = scan; self.upload = upload; self.submitting = submitting
        }
    }

    public struct Loading: Codable, Equatable, Sendable {
        public var `default`: String?
        public var verifying: String?
        public var submittingDocument: String?
        public var checkingQuality: String?
        public init(
            default defaultLabel: String? = nil, verifying: String? = nil,
            submittingDocument: String? = nil, checkingQuality: String? = nil
        ) {
            self.default = defaultLabel; self.verifying = verifying
            self.submittingDocument = submittingDocument; self.checkingQuality = checkingQuality
        }
    }

    public struct Face: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public var start: String?
        public init(title: String? = nil, body: String? = nil, start: String? = nil) {
            self.title = title; self.body = body; self.start = start
        }
    }

    public struct Document: Codable, Equatable, Sendable {
        public var selectTitle: String?
        public var selectBody: String?
        public var primerTitle: String?
        public var primerBody: String?
        public var uploadTitle: String?
        public var uploadBody: String?
        public var scanTitle: String?
        public var scanBody: String?
        public var confirmTitle: String?
        public var confirmBody: String?
        public init(
            selectTitle: String? = nil, selectBody: String? = nil,
            primerTitle: String? = nil, primerBody: String? = nil,
            uploadTitle: String? = nil, uploadBody: String? = nil,
            scanTitle: String? = nil, scanBody: String? = nil,
            confirmTitle: String? = nil, confirmBody: String? = nil
        ) {
            self.selectTitle = selectTitle; self.selectBody = selectBody
            self.primerTitle = primerTitle; self.primerBody = primerBody
            self.uploadTitle = uploadTitle; self.uploadBody = uploadBody
            self.scanTitle = scanTitle; self.scanBody = scanBody
            self.confirmTitle = confirmTitle; self.confirmBody = confirmBody
        }
    }

    public struct Form: Codable, Equatable, Sendable {
        public var title: String?
        public init(title: String? = nil) { self.title = title }
    }

    public struct IdNumber: Codable, Equatable, Sendable {
        public var title: String?
        public var body: String?
        public init(title: String? = nil, body: String? = nil) {
            self.title = title; self.body = body
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var successTitle: String?
        public var successBody: String?
        public var reviewTitle: String?
        public var reviewBody: String?
        public var notVerifiedTitle: String?
        public var notVerifiedBody: String?
        public var cancelledTitle: String?
        public init(
            successTitle: String? = nil, successBody: String? = nil,
            reviewTitle: String? = nil, reviewBody: String? = nil,
            notVerifiedTitle: String? = nil, notVerifiedBody: String? = nil,
            cancelledTitle: String? = nil
        ) {
            self.successTitle = successTitle; self.successBody = successBody
            self.reviewTitle = reviewTitle; self.reviewBody = reviewBody
            self.notVerifiedTitle = notVerifiedTitle; self.notVerifiedBody = notVerifiedBody
            self.cancelledTitle = cancelledTitle
        }
    }

    public struct Errors: Codable, Equatable, Sendable {
        public var generic: String?
        public var providerUnavailable: String?
        public var documentUnreadable: String?
        public init(generic: String? = nil, providerUnavailable: String? = nil, documentUnreadable: String? = nil) {
            self.generic = generic; self.providerUnavailable = providerUnavailable
            self.documentUnreadable = documentUnreadable
        }
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public var disclosure: String?
        public var consentTitle: String?
        public var consentBody: String?
        public init(disclosure: String? = nil, consentTitle: String? = nil, consentBody: String? = nil) {
            self.disclosure = disclosure; self.consentTitle = consentTitle; self.consentBody = consentBody
        }
    }

    public init(
        welcome: Welcome? = nil,
        buttons: Buttons? = nil,
        loading: Loading? = nil,
        face: Face? = nil,
        document: Document? = nil,
        form: Form? = nil,
        idNumber: IdNumber? = nil,
        result: Result? = nil,
        errors: Errors? = nil,
        privacy: Privacy? = nil,
        help: [String: String]? = nil
    ) {
        self.welcome = welcome
        self.buttons = buttons
        self.loading = loading
        self.face = face
        self.document = document
        self.form = form
        self.idNumber = idNumber
        self.result = result
        self.errors = errors
        self.privacy = privacy
        self.help = help
    }
}

// MARK: - Merge

public extension FlowCopy {
    /// Deep-merge a higher-priority copy over a lower one (SDK > server).
    /// Field-level: any non-blank value set on `high` wins; otherwise `low`
    /// shows through. A cleared (empty/whitespace) override is treated as unset
    /// so a blanked dashboard field never erases the built-in copy — see `txt`.
    static func merge(high: FlowCopy?, low: FlowCopy?) -> FlowCopy? {
        guard let high else { return low }
        guard let low else { return high }
        return FlowCopy(
            welcome: Welcome(
                title: high.welcome?.title ?? low.welcome?.title,
                body: high.welcome?.body ?? low.welcome?.body
            ),
            buttons: Buttons(
                continue: high.buttons?.continue ?? low.buttons?.continue,
                cancel: high.buttons?.cancel ?? low.buttons?.cancel,
                tryAgain: high.buttons?.tryAgain ?? low.buttons?.tryAgain,
                retake: high.buttons?.retake ?? low.buttons?.retake,
                useThisPhoto: high.buttons?.useThisPhoto ?? low.buttons?.useThisPhoto,
                uploadInstead: high.buttons?.uploadInstead ?? low.buttons?.uploadInstead,
                scan: high.buttons?.scan ?? low.buttons?.scan,
                upload: high.buttons?.upload ?? low.buttons?.upload,
                submitting: high.buttons?.submitting ?? low.buttons?.submitting
            ),
            loading: Loading(
                default: high.loading?.default ?? low.loading?.default,
                verifying: high.loading?.verifying ?? low.loading?.verifying,
                submittingDocument: high.loading?.submittingDocument ?? low.loading?.submittingDocument,
                checkingQuality: high.loading?.checkingQuality ?? low.loading?.checkingQuality
            ),
            face: Face(
                title: high.face?.title ?? low.face?.title,
                body: high.face?.body ?? low.face?.body,
                start: high.face?.start ?? low.face?.start
            ),
            document: Document(
                selectTitle: high.document?.selectTitle ?? low.document?.selectTitle,
                selectBody: high.document?.selectBody ?? low.document?.selectBody,
                primerTitle: high.document?.primerTitle ?? low.document?.primerTitle,
                primerBody: high.document?.primerBody ?? low.document?.primerBody,
                uploadTitle: high.document?.uploadTitle ?? low.document?.uploadTitle,
                uploadBody: high.document?.uploadBody ?? low.document?.uploadBody,
                scanTitle: high.document?.scanTitle ?? low.document?.scanTitle,
                scanBody: high.document?.scanBody ?? low.document?.scanBody,
                confirmTitle: high.document?.confirmTitle ?? low.document?.confirmTitle,
                confirmBody: high.document?.confirmBody ?? low.document?.confirmBody
            ),
            form: Form(title: high.form?.title ?? low.form?.title),
            idNumber: IdNumber(
                title: high.idNumber?.title ?? low.idNumber?.title,
                body: high.idNumber?.body ?? low.idNumber?.body
            ),
            result: Result(
                successTitle: high.result?.successTitle ?? low.result?.successTitle,
                successBody: high.result?.successBody ?? low.result?.successBody,
                reviewTitle: high.result?.reviewTitle ?? low.result?.reviewTitle,
                reviewBody: high.result?.reviewBody ?? low.result?.reviewBody,
                notVerifiedTitle: high.result?.notVerifiedTitle ?? low.result?.notVerifiedTitle,
                notVerifiedBody: high.result?.notVerifiedBody ?? low.result?.notVerifiedBody,
                cancelledTitle: high.result?.cancelledTitle ?? low.result?.cancelledTitle
            ),
            errors: Errors(
                generic: high.errors?.generic ?? low.errors?.generic,
                providerUnavailable: high.errors?.providerUnavailable ?? low.errors?.providerUnavailable,
                documentUnreadable: high.errors?.documentUnreadable ?? low.errors?.documentUnreadable
            ),
            privacy: Privacy(
                disclosure: high.privacy?.disclosure ?? low.privacy?.disclosure,
                consentTitle: high.privacy?.consentTitle ?? low.privacy?.consentTitle,
                consentBody: high.privacy?.consentBody ?? low.privacy?.consentBody
            ),
            help: mergeHelp(high: high.help, low: low.help)
        )
    }

    private static func mergeHelp(high: [String: String]?, low: [String: String]?) -> [String: String]? {
        guard let high else { return low }
        guard let low else { return high }
        return low.merging(high) { _, new in new }
    }
}

// MARK: - JSON decode (server payload)

public extension FlowCopy {
    /// Decode a FlowCopy from a JSONSerialization object (the heterogeneous
    /// branding payload is parsed with JSONSerialization upstream, so we
    /// re-encode the `copy` sub-object and run it through Codable). The wire
    /// shape is camelCase (matching the web contract keys), which lines up 1:1
    /// with these property names. Returns nil rather than throwing so a
    /// malformed payload degrades to the built-in copy instead of failing the run.
    static func decodeFromJSONObject(_ object: [String: Any]) -> FlowCopy? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(FlowCopy.self, from: data)
    }
}
