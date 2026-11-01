#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

public final class UseSenseViewController: UIViewController {
    private let session: UseSenseSession
    private var onComplete: ((Result<RedactedDecisionObject, UseSenseError>) -> Void)?
    private var hostingController: UIHostingController<UseSenseView>?
    /// True when this controller seeded FlowAppearanceResolver itself, so it
    /// clears only what it set (a Flow runner owns the resolver during a run).
    private var seededAppearance = false
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

        // The capture screens read the brand tokens from FlowAppearanceResolver.
        // Inside a Flow the runner has already set it; a standalone session
        // themes from its own SDK-init branding.
        if FlowAppearanceResolver.current == nil, let appearance = session.brandingAppearance {
            FlowAppearanceResolver.set(appearance)
            seededAppearance = true
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
        if seededAppearance, isBeingDismissed || presentingViewController == nil {
            FlowAppearanceResolver.reset()
            seededAppearance = false
        }
    }
}
#endif
