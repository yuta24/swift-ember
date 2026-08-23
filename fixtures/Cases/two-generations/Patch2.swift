@testable import Fixture

extension Accumulator {
    @_dynamicReplacement(for: add())
    mutating func patched_add_g2() { total += 1_000_000 }
}
