@testable import Fixture

private func rate() -> Int { 10 }

extension Meter {
    @_dynamicReplacement(for: reading())
    func patched_reading_g1() -> String { "\(ticks * rate())" }
}
