// SwiftUI's `View` is the one protocol measured to carry a type eraser:
//
//     @_typeEraser(DebugReplaceableView) @_typeEraser(AnyView) protocol View
//
// Which of the two applies depends on the deployment target, and this case
// originally asserted the wrong thing by naming one of them. DebugReplaceableView
// is available from iOS 26 and macOS 26; below that the compiler falls back to
// AnyView. Both are concrete types, so the property that matters -- that the
// return type is fixed and a change of view tree shape cannot strand a caller
// holding stale metadata -- holds either way. CI on a macOS 15 runner is what
// noticed; no machine here targets anything old enough.
//
// So `some View` is already a concrete type and changing the shape of a view
// tree is not the undefined-behaviour case that Cases/opaque-result-type-changed
// documents. This pins two halves of that claim: the patch loads without
// corrupting anything, and a direct read of `body` really does reach it.
//
// What it cannot pin is the half that matters most, and this case passing
// while the claim above it was wrong is how that half stayed wrong twice. In
// a rendering app the replacement *does* run and *does* render -- and then
// aborts the process if the body's concrete type changed and the view is a
// row of a List, because SwiftUI's own storage is generic and the graph
// downcasts it. A direct read of `body` never touches that storage, which is
// exactly why this case is quiet about it. DESIGN.md 13.1; only observable
// with a UI.

import SwiftUI

nonisolated(unsafe) var evaluations: [String] = []

struct Screen: View {
    var body: some View {
        evaluations.append("old")
        return Text("old")
    }
}

nonisolated(unsafe) let screen = Screen()

func probe() async throws -> [String] {
    evaluations.removeAll()
    let body = await MainActor.run { screen.body }
    // Named erasers rather than "not Text": the claim is that one of View's
    // declared type erasers applied, and a toolchain that stopped erasing
    // should fail here rather than quietly report a different name.
    let erasers = ["DebugReplaceableView", "AnyView"]
    return ["evaluated=\(evaluations.joined(separator: ","))",
            "erased=\(erasers.contains(String(describing: type(of: body))))"]
}
