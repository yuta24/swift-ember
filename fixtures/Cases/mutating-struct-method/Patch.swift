@testable import Fixture

extension Accumulator {
    @_dynamicReplacement(for: add())
    mutating func patched_add() { total += 1000 }
}
