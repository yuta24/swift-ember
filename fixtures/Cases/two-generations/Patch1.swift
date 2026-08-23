@testable import Fixture

extension Accumulator {
    @_dynamicReplacement(for: add())
    mutating func patched_add_g1() { total += 1000 }
}
