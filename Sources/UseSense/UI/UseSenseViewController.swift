#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

public final class UseSenseViewController: UIViewController {
    private let session: UseSenseSession
    private var onComplete: ((Result<RedactedDecisionObject, UseSenseError>) -> Void)?
    private var hostingController: UIHostingController<UseSenseView>?
    /// The brand this controller seeded itself, so it clears only what it set
    /// (a Flow runner owns the resolvers during a run).
    private let brandSeed = CaptureBrandSeed()
    /// When true the controller dismisses itself first and reports the result
    /// in the dismissal's completion. The Flows runner sets it: it presents its
    /// next surface (or an error screen) from the callback, and a present
    /// issued while this controller is still dismissing is dropped by UIKit,
    /// leaving the subject on a blank runner. Off by default so integrators
    /// that dismiss from the callback keep today's order.
    var dismissesBeforeCallback = false

    public init(
        session: UseSenseSession,
        onComplete: @escaping (Result<RedactedDecisionObject, UseSenseError>) -> Void
    ) {
        self.session = session
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // The capture screens read the brand from the resolvers. Inside a Flow
        // the runner has already resolved them (code > Flow > org) and owns
        // them. A standalone session owns them here: it themes from the
        // code-set branding at once, then folds the dashboard branding in
        // underneath when the session response delivers it ("code wins").
        if brandSeed.seed(appearance: session.brandingAppearance, copy: session.brandingCopy,
                          displayName: session.brandDisplayName) {
            session.onBrandingAvailable = { [weak self, weak session] appearance in
                guard let self, let session, self.brandSeed.owns else { return }
                self.brandSeed.seed(appearance: appearance, copy: session.brandingCopy,
                                    displayName: session.brandDisplayName)
            }
        }

        // This controller seeds the brand itself (above), so the hosted view
        // must not seed a second time.
        let useSenseView = UseSenseView(
            session: session,
            onComplete: { [weak self] result in
                self?.deliver(result)
            },
            onCancel: { [weak self] in
                self?.deliver(.failure(UseSenseError(code: .userCancelled)))
            },
            seedsBranding: false
        )

        let hosting = UIHostingController(rootView: useSenseView)
        hostingController = hosting

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hosting.didMove(toParent: self)
    }

    /// Stops the capture (camera, microphone, uploads) and reports
    /// `userCancelled` to the completion handler, once. Use it when your
    /// screen removes or replaces an embedded capture before it finishes.
    /// Safe to call more than once or after the capture has finished.
    public func cancel() {
        guard onComplete != nil else { return }
        session.cancel()
        deliver(.failure(UseSenseError(code: .userCancelled)))
    }

    /// True when this controller is the one that was presented, so closing the
    /// capture means dismissing it. False when it is a child embedded in the
    /// host's own screen (React Native, Flutter, a container view): dismissing
    /// then would close the host's screen instead. A controller pushed onto a
    /// navigation controller keeps the old behaviour (the navigation controller
    /// was presented for it).
    private var ownsPresentation: Bool {
        guard presentingViewController != nil else { return false }
        guard let parent else { return true }
        return parent is UINavigationController
    }

    /// True while this controller is going away for good: dismissed, removed
    /// from its parent, or inside a container that is being dismissed or
    /// removed. Not true when another screen is merely pushed or presented
    /// over it.
    private var isTearingDown: Bool {
        if parent == nil && presentingViewController == nil { return true }
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent
        }
        return false
    }

    private func deliver(_ result: Result<RedactedDecisionObject, UseSenseError>, closing: Bool = true) {
        guard let callback = onComplete else { return }
        // Exactly once: a second tap or a late state change must not report twice.
        onComplete = nil
        let dismissesSelf = closing && ownsPresentation && !isBeingDismissed
        if dismissesBeforeCallback {
            if dismissesSelf {
                dismiss(animated: true) { callback(result) }
            } else {
                callback(result)
            }
        } else {
            callback(result)
            if dismissesSelf { dismiss(animated: true) }
        }
    }

    /// The host took the capture away before it finished: stop the camera and
    /// report a cancellation once, without trying to close anything.
    private func abandonIfPending() {
        guard onComplete != nil else { return }
        session.cancel()
        if dismissesBeforeCallback {
            // Inside a Flow the runner closed this screen itself (an error or
            // the next surface). A cancellation report would make it cancel
            // the run, so only the camera stops.
            onComplete = nil
            return
        }
        deliver(.failure(UseSenseError(code: .userCancelled)), closing: false)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isTearingDown else { return }
        abandonIfPending()
        if brandSeed.owns { brandSeed.clear() }
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        // Removed from a container without the view disappearing first (or
        // before it ever appeared).
        guard parent == nil, isViewLoaded, presentingViewController == nil else { return }
        abandonIfPending()
        if brandSeed.owns { brandSeed.clear() }
    }
}
#endif
