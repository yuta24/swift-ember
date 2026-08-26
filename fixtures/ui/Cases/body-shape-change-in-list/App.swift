// A `some View` body whose concrete type changes, in a List.
//
// DESIGN.md 13.1: the erasure makes the return type concrete and keeps the
// child in a generic box, and the graph downcasts that box to the type it saw
// first. Changing the type aborts the process -- but only where the view is a
// row of something that builds a view list, which is what this case is for.
//
// `tick` is what makes the body evaluate again. Without it SwiftUI compares
// the view equal to its predecessor and never calls the body at all, which is
// the confound that produced two wrong conclusions before this case existed.

import SwiftUI

struct Row: View {
    var tick: Int
    var body: some View {
        Text("row \(tick)")
    }
}

struct Host: View {
    @State private var tick = 0

    var body: some View {
        List {
            Row(tick: tick)
            Text("tick \(tick)")
        }
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await UIHarness.loadPatches() }
                group.addTask { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        tick += 1
                        UIHarness.beat(tick, rendered: "tick \(tick)")
                    }
                }
            }
        }
    }
}

@main
struct FixtureApp: App {
    var body: some Scene { WindowGroup { Host() } }
}
