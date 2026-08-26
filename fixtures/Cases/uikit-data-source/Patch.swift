@testable import Fixture
import UIKit

extension Rows {
    @_dynamicReplacement(for: tableView(_:cellForRowAt:))
    func patched_cellForRowAt(_ table: UITableView, _ path: IndexPath) -> UITableViewCell {
        trace.append("cellForRowAt=new")
        let cell = UITableViewCell()
        cell.textLabel?.text = "row=new"
        return cell
    }
}
