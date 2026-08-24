// SwiftUI's `View` is the one protocol measured to carry a type eraser:
//
//     @_typeEraser(DebugReplaceableView) @_typeEraser(AnyView) protocol View
//
// So `some View` is already a concrete type and changing the shape of a view
// tree is not the undefined-behaviour case that Cases/opaque-result-type-changed
// documents. This pins two halves of that claim: the patch loads without
// corrupting anything, and a direct read of `body` really does reach it.
//
// What it cannot pin is the half that matters most. In a rendering app the
// replacement changes nothing on screen, because SwiftUI does not evaluate a
// body through it -- measured in DESIGN.md 13, and only observable with a UI.

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
    return ["evaluated=\(evaluations.joined(separator: ","))",
            "erased-to=\(type(of: body))"]
}
