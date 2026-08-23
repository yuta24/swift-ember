import Foundation
import SpliceRuntime

/// The subject of the hot reload, same shape as examples/CounterApp.
///
/// Stored properties define the layout and must not change while the process
/// is alive. The method bodies are what a patch replaces.
final class Cart: ObservableObject {
    /// Generated once per launch. If it survives a reload, the process was
    /// never restarted.
    let sessionToken: String

    @Published private(set) var items: [Item] = []
    @Published private(set) var reloadLog: [String] = []
    @Published private(set) var connected = false

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let cents: Int
    }

    init() {
        sessionToken = String(format: "%06X", UInt32.random(in: 0..<0xFFFFFF))
        items = [Item(name: "Coffee", cents: 450), Item(name: "Bagel", cents: 325)]
    }

    func add(_ name: String, cents: Int) {
        items.append(Item(name: name, cents: cents))
    }

    var subtotalCents: Int { items.reduce(0) { $0 + $1.cents } }

    /// Mirrors the runtime's status into the view. The runtime knows nothing
    /// about SwiftUI, so the adapting happens here rather than there.
    func apply(_ status: Splice.Status) {
        connected = status.connected
        reloadLog = status.lines
    }

    // MARK: - Patchable

    func subtotalLabel() -> String {
        "\(subtotalCents) cents"
    }

    func discountLabel() -> String {
        "none"
    }
}
