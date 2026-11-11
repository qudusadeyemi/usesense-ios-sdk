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

        let useSenseView = UseSenseView(
            session: session,
            onComplete: { [weak self] result in
                self?.deliver(result)
            },
            onCancel: { [weak self] in
                self?.deliver(.failure(UseSenseError(code: .userCancelled)))
            }
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

    private func deliver(_ result: Result<RedactedDecisionObject, UseSenseError>) {
        guard let callback = onComplete else { return }
        // Exactly once: a second tap or a late state change must not report twice.
        onComplete = nil
        if dismissesBeforeCallback {
            if presentingViewController != nil {
                dismiss(animated: true) { callback(result) }
            } else {
                callback(result)
            }
        } else {
            callback(result)
            dismiss(animated: true)
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if brandSeed.owns, isBeingDismissed || presentingViewController == nil {
            brandSeed.clear()
        }
    }
}
#endif
