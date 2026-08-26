// The one UIKit entry point a reload cannot reach on its own.
//
// `viewDidLoad` runs once per loaded view. Replacing it is correct and takes
// effect nowhere, because nothing calls it again -- the same shape as a
// SwiftUI body whose view is never re-evaluated (DESIGN.md section 13.1).
//
// Discarding the controller's view does re-run it, the controller's own state
// survives, and the rebuilt view is not put back where the old one was --- all
// three are measured below. The third is why the runtime deliberately does not
// do this: a controller's view is held by whatever installed it. Tried on the
// example app it left a black window. What this case pins is the mechanism,
// not a supported operation.

import UIKit

nonisolated(unsafe) var trace: [String] = []

final class Screen: UIViewController {
    /// Predates every patch. Still here after a view reload means the
    /// controller was rebuilt from the outside in, not thrown away.
    let session = "abc123"

    override func viewDidLoad() {
        super.viewDidLoad()
        trace.append("viewDidLoad=old")
        let label = UILabel()
        label.text = "old"
        view.addSubview(label)
    }

    func labels() -> [String] { view.subviews.compactMap { ($0 as? UILabel)?.text } }
}

// `UIWindow(frame:)` is deprecated in iOS 26 in favour of the scene
// initialiser, which a console process has no scene for. The frame is set
// afterwards instead; the window only has to be big enough to lay out in.
nonisolated(unsafe) let window: UIWindow = {
    let window = UIWindow()
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    return window
}()
nonisolated(unsafe) let screen = Screen()
nonisolated(unsafe) var attached = false

@MainActor func probe() async throws -> [String] {
    if !attached {
        window.rootViewController = screen
        window.isHidden = false
        _ = screen.view
        window.layoutIfNeeded()
        attached = true
    }

    var lines: [String] = []

    // 1. Nothing calls viewDidLoad again, so a patch alone changes nothing.
    trace = []
    screen.view.setNeedsLayout()
    screen.view.layoutIfNeeded()
    lines.append("nudged: \(trace.isEmpty ? "not called" : trace.joined(separator: " ")) labels=\(screen.labels())")

    // 2. Discarding the view makes UIKit load it again.
    trace = []
    screen.view = nil
    _ = screen.view
    window.layoutIfNeeded()
    // `inWindow` is the half that stops this case from claiming too much. The
    // rebuilt view has the new label, and it is not where the old one was --
    // whatever installed the old view still holds it. That is why the runtime
    // does not do this.
    lines.append("reloaded: \(trace.joined(separator: " ")) labels=\(screen.labels()) "
                 + "session=\(screen.session) inWindow=\(screen.view.superview != nil)")

    return lines
}
