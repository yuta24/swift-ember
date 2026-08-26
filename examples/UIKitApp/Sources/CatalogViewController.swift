import UIKit
import SpliceRuntime

/// The list, out of a storyboard and inside a navigation controller.
///
/// Everything here is reached by UIKit calling it again, which is what makes
/// UIKit different from SwiftUI (DESIGN.md sections 13 and 13a):
///
/// - `tableView(_:cellForRowAt:)` runs on the `reloadData()` the runtime sends;
/// - `viewDidLoad` has already run and `watch` says so;
/// - `title(for:)` is an ordinary method the two above call, so editing it is
///   the shortest path from a save to a changed screen.
final class CatalogViewController: UITableViewController {
    private let catalog = Catalog.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = heading()
        navigationItem.prompt = "session \(catalog.session)"
    }

    /// Called from `viewDidLoad`, so editing it needs a new controller ---
    /// navigate back and in again --- and `watch` says which of the two you
    /// are looking at.
    func heading() -> String {
        "Catalog"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        catalog.items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        (cell as? RowCell)?.show(catalog.items[indexPath.row])
        return cell
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let detail = segue.destination as? DetailViewController,
              let row = tableView.indexPathForSelectedRow?.row else { return }
        detail.index = row
    }
}
