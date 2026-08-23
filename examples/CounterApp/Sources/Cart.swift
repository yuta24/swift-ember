import Foundation

/// The subject of the hot reload.
///
/// Stored properties here define the object's layout and must not change while
/// the process is alive. The method bodies are what a patch replaces.
final class Cart: ObservableObject {
    /// Generated once per launch. If this string survives a reload, the process
    /// was never restarted.
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
        var generator = SystemRandomNumberGenerator()
        sessionToken = String(format: "%06X", UInt32.random(in: 0..<0xFFFFFF, using: &generator))
        items = [Item(name: "Coffee", cents: 450), Item(name: "Bagel", cents: 325)]
    }

    func add(_ name: String, cents: Int) {
        items.append(Item(name: name, cents: cents))
    }

    func note(_ line: String) {
        reloadLog.append(line)
    }

    #if SPLICE_ENABLED
    /// Mirrors the runtime's status into the view. The runtime knows nothing
    /// about SwiftUI, so the adapting happens here rather than there.
    func apply(_ status: Splice.Status) {
        connected = status.connected
        reloadLog = status.lines
    }
    #endif

    // MARK: - Patchable

    /// Replaced by Patches/Patch1.swift.
    func subtotalLabel() -> String {
        "\(subtotalCents) cents"
    }

    /// Replaced by Patches/Patch2.swift, which also demonstrates that the
    /// newest generation wins.
    func discountLabel() -> String {
        "none"
    }

    var subtotalCents: Int {
        items.reduce(0) { $0 + $1.cents }
    }
}
