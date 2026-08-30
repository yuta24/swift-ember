// The proposed SwiftUI opt-in, exercised at the exact boundary where an
// un-erased body aborts: a row of a List on iOS 26 or later.
//
// `@ObserveEmber` invalidates Row itself after dlopen, so SwiftUI calls the
// replaced body. `emberable()` makes the child stored by
// DebugReplaceableView an AnyView in both generations. The UUID belongs to
// Row's @State and proves that making the new tree visible did not replace the
// Row value's SwiftUI state.

import SwiftUI
import EmberSwiftUI
import UIKit

private func loadEmberPatches() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(300))
        let loaded = Ember.loadPendingPatches()
        guard !loaded.isEmpty else { continue }

        let inbox = UIHarness.documents.appendingPathComponent("Patches", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".dylib") {
            let path = inbox.appendingPathComponent(name).path
            UIHarness.recordRegistered(RegisteredReplacements.count(inImageAt: path))
        }
    }
}

struct RenderProbe: UIViewRepresentable {
    let value: String

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ uiView: UIView, context: Context) {
        UIHarness.render(value)
    }
}

struct Row: View {
    var tick: Int
    @State var stateID = UUID().uuidString
    @ObserveEmber private var ember

    var body: some View {
        Text("old \(tick)")
            .background(RenderProbe(value: "old|\(stateID)"))
            .emberable()
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
                group.addTask { await loadEmberPatches() }
                group.addTask { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        tick += 1
                        UIHarness.heartbeat(tick)
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
