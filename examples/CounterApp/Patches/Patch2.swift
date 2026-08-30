// A second generation. Loading this after Patch1 shows that the most recently
// loaded replacement wins, and that Patch1's replacement of a different method
// is unaffected.

@testable import CounterApp

extension Cart {
    @_dynamicReplacement(for: discountLabel())
    func ember_g2_discountLabel() -> String {
        subtotalCents >= 1000 ? "10% off orders over $10" : "spend $10 to unlock"
    }
}
