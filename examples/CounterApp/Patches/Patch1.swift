// Hand-authored replacement, the M1 stand-in for what the generator will emit
// in M2. Only method bodies change; Cart's stored properties are untouched, so
// the live instance stays valid.

@testable import CounterApp

extension Cart {
    @_dynamicReplacement(for: subtotalLabel())
    func ember_g1_subtotalLabel() -> String {
        let dollars = Double(subtotalCents) / 100
        return String(format: "$%.2f across %d item(s)", dollars, items.count)
    }
}
