import UIKit

/// A prototype cell out of the storyboard, so `awakeFromNib` is a real nib
/// callback here rather than a name in a list.
///
/// It is one-shot per cell, and a table view keeps its cells in a reuse pool,
/// so an edit reaches a cell the pool has not made yet -- which is what `watch`
/// says about it.
final class RowCell: UITableViewCell {
    @IBOutlet private var name: UILabel!
    @IBOutlet private var detail: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        name.font = .preferredFont(forTextStyle: .body)
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabel
    }

    func show(_ item: Catalog.Item) {
        name.text = item.name
        detail.text = Catalog.shared.subtitle(for: item)
    }
}
