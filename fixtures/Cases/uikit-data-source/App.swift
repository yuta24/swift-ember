// A data source method: called again on reloadData, which is the nudge a
// UIKit adapter sends to a table or collection view.
//
// What is different from uikit-live-instance is the *declaration* -- a
// protocol requirement satisfied by a separate object, not an override on a
// subclass. The dispatch is not: `UITableViewDataSource` is an `@objc`
// protocol, so UIKit sends a message, and the patch carries an Objective-C
// category exactly as the override case does. Checked rather than assumed:
// `otool -l` on this case's patch shows `__objc_catlist` and no
// `__swift5_replace`, where the host case `protocol-witness` shows the
// reverse. A Swift protocol witness is that other case's business.

import UIKit

nonisolated(unsafe) var trace: [String] = []

final class Rows: NSObject, UITableViewDataSource {
    func tableView(_ table: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ table: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        trace.append("cellForRowAt=old")
        let cell = UITableViewCell()
        cell.textLabel?.text = "row=old"
        return cell
    }
}

// `UIWindow(frame:)` is deprecated in iOS 26 in favour of the scene
// initialiser, which a console process has no scene for. The frame is set
// afterwards instead; the window only has to be big enough to lay out in.
nonisolated(unsafe) let window: UIWindow = {
    let window = UIWindow()
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    return window
}()
nonisolated(unsafe) let rows = Rows()
nonisolated(unsafe) let table = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
nonisolated(unsafe) var attached = false

@MainActor func probe() async throws -> [String] {
    if !attached {
        table.dataSource = rows
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(table)
        window.isHidden = false
        attached = true
    }

    trace = []
    table.reloadData()
    table.layoutIfNeeded()
    // Read one cell back rather than trust that layout asked for it: an
    // off-screen table can decide it needs no rows at all.
    let cell = rows.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
    return ["\(trace.joined(separator: " ")) text=\(cell.textLabel?.text ?? "nil")"]
}
