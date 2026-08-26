import UIKit

/// The pushed screen, with an outlet and an action out of the same storyboard.
///
/// `refresh()` is called from `viewWillLayoutSubviews`, so the runtime's own
/// invalidation is enough to run a new version of it: save, and the label
/// changes with no tap and no navigation.
final class DetailViewController: UIViewController {
    @IBOutlet private var headline: UILabel!
    @IBOutlet private var footnote: UILabel!

    var index = 0
    private let catalog = Catalog.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        headline.numberOfLines = 0
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        refresh()
    }

    /// Edit this with `swift-splice watch` running.
    func refresh() {
        headline.text = catalog.headline(for: catalog.items[index])
        footnote.text = "session \(catalog.session)"
    }

    /// An `@IBAction` is `@objc`, so its replacement arrives as an
    /// Objective-C category rather than a Swift replacement record
    /// (DESIGN.md section 13a.2). Nothing needs to be refreshed for it: the
    /// next tap calls the new body.
    @IBAction func bump(_ sender: UIButton) {
        catalog.bumpPrice(of: index)
        view.setNeedsLayout()
    }
}
