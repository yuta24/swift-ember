@testable import Fixture

// A free function that exists only here.
func splice_dollars(_ cents: Int) -> String { "$\(cents / 100).\(cents % 100)" }

extension Cart {
    // A new method on an existing type, added by the patch rather than replacing
    // anything. Legal because an extension may add members.
    func splice_total() -> Int { items.reduce(0, +) }

    @_dynamicReplacement(for: label())
    func patched_label() -> String { splice_dollars(splice_total()) }
}
