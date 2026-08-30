import UIKit
import SwiftUI

/// The UIKit half of the example.
///
/// A `some View` body cannot be reloaded (DESIGN.md section 13), so everything
/// on this screen that changes while the app runs goes through UIKit, which
/// dispatches at call time and therefore reaches a replacement.
///
/// Three shapes are on display, and the CLI says something different about
/// each:
///
/// - `total()` is an ordinary method. It is called from
///   `viewWillLayoutSubviews`, so the runtime's refresh is enough to run it.
/// - `viewWillLayoutSubviews` is called again on every layout pass, so
///   editing it is enough on its own.
/// - `viewDidLoad` has already run. `watch` says so rather than reporting a
///   reload the screen does not show. Nothing makes it visible on this
///   controller: the new body reaches the next one created.
final class ReceiptController: UIViewController {
    private let label = UILabel()
    private let cart: Cart

    init(cart: Cart) {
        self.cart = cart
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        label.text = total()
    }

    /// Edit this body with `swift-ember watch` running.
    func total() -> String {
        let cents = cart.items.reduce(0) { $0 + $1.cents }
        return "UIKit total: \(cents) cents"
    }
}

struct Receipt: UIViewControllerRepresentable {
    let cart: Cart

    func makeUIViewController(context: Context) -> ReceiptController {
        ReceiptController(cart: cart)
    }

    /// Left empty on purpose. The point of this screen is that the reload
    /// reaches it without SwiftUI being involved at all.
    func updateUIViewController(_ controller: ReceiptController, context: Context) {}
}
