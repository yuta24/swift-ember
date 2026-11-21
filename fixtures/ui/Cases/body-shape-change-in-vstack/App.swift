// The same edit, in a VStack, which does not abort.
//
// DESIGN.md 13.1: on the iOS 26 runtimes, changing the type in a List row
// reaches the cast that aborts. This case is the container control. The same
// Text-to-VStack change survives in a VStack.
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
        VStack {
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
