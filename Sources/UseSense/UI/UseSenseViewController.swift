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
                self?.onComplete?(result)
                self?.dismiss(animated: true)
            },
            onCancel: { [weak self] in
                self?.onComplete?(.failure(UseSenseError(code: .userCancelled)))
                self?.dismiss(animated: true)
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

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if seededAppearance, isBeingDismissed || presentingViewController == nil {
            FlowAppearanceResolver.reset()
            seededAppearance = false
        }
    }
}
#endif
