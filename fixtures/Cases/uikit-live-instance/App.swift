// Everything UIKit calls again on its own, measured on the instance that is
// already on screen rather than on a fresh one.
//
// This is the case SwiftUI fails (DESIGN.md section 13): there the graph
// re-runs and still reaches the original body. UIKit dispatches at call time,
// through the vtable or through objc_msgSend, so the same nudge a refresh
// would send reaches the replacement.

import UIKit

nonisolated(unsafe) var trace: [String] = []

final class Screen: UIViewController {
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        trace.append("viewWillLayoutSubviews=old")
    }

    /// Stands in for an @IBAction or a delegate callback: something calls it
    /// later, so no refresh is needed for the new body to run.
    @objc func tapped() { trace.append("tapped=old") }
}

final class Box: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        trace.append("layoutSubviews=old")
    }

    override func draw(_ rect: CGRect) { trace.append("draw=old") }
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
nonisolated(unsafe) let box = Box(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
nonisolated(unsafe) var attached = false

@MainActor func probe() async throws -> [String] {
    if !attached {
        window.rootViewController = screen
        window.isHidden = false
        screen.view.addSubview(box)
        window.layoutIfNeeded()
        attached = true
    }

    // The nudges a UIKit adapter sends after a generation loads.
    trace = []
    screen.view.setNeedsLayout()
    screen.view.layoutIfNeeded()
    box.setNeedsLayout()
    box.layoutIfNeeded()
    box.setNeedsDisplay()
    // draw(_:) waits for a render pass; force one rather than wait for a
    // frame. It is recorded twice because the invalidated layer draws once
    // when it is rendered and once when the renderer asks for its contents;
    // what matters is that both are the replacement.
    let renderer = UIGraphicsImageRenderer(size: box.bounds.size)
    _ = renderer.image { context in box.layer.render(in: context.cgContext) }
    screen.tapped()

    return trace
}
