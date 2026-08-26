import Foundation

/// The model, shared by both screens.
///
/// Its lifetime is the process's, so anything it holds is the evidence that a
/// reload did not restart anything. `session` is printed on both screens.
final class Catalog {
    static let shared = Catalog()

    /// Generated once per launch. If it survives an edit, the process did.
    let session = String(format: "%06X", UInt32.random(in: 0..<0xFFFFFF))

    struct Item {
        let name: String
        let cents: Int
    }

    private(set) var items: [Item] = [
        Item(name: "Coffee", cents: 450),
        Item(name: "Bagel", cents: 325),
        Item(name: "Orange juice", cents: 500),
    ]

    /// Reached from `cellForRowAt`, so a `reloadData()` is enough to run it.
    /// Edit this and the whole list changes without a tap.
    func subtitle(for item: Item) -> String {
        "\(item.cents) cents"
    }

    /// Reached from the detail screen's layout pass.
    func headline(for item: Item) -> String {
        "\(item.name) — \(subtitle(for: item))"
    }

    func bumpPrice(of index: Int) {
        items[index] = Item(name: items[index].name, cents: items[index].cents + 25)
    }
}
