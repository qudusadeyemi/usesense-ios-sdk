#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

public protocol UseSenseDelegate: AnyObject {
    func useSense(_ viewController: UseSenseViewController, didFinishWith result: UseSenseResult)
    func useSense(_ viewController: UseSenseViewController, didFailWith error: UseSenseError)
    func useSenseDidCancel(_ viewController: UseSenseViewController)
}

public final class UseSenseViewController: UIViewController {
    public weak var delegate: UseSenseDelegate?
    private let request: VerificationRequest
    private var hostingController: UIHostingController<AnyView>?

    public init(request: VerificationRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let config = UseSense.shared.config else {
            delegate?.useSense(self, didFailWith: UseSenseError(code: .invalidConfig, message: "UseSense has not been configured. Call UseSense.configure() first."))
            return
        }

        let verificationView = UseSenseVerificationView(
            config: config,
            theme: UseSense.shared.theme,
            request: request,
            onResult: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let verdict):
                    self.delegate?.useSense(self, didFinishWith: verdict)
                case .failure(let error):
                    self.delegate?.useSense(self, didFailWith: error)
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                self.delegate?.useSenseDidCancel(self)
            }
        )

        let hosting = UIHostingController(rootView: AnyView(verificationView))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    public override var prefersStatusBarHidden: Bool { true }
}
#endif
