@testable import Fixture

private func rate() -> Int { 100 }

extension Meter {
    @_dynamicReplacement(for: reading())
    func patched_reading_g2() -> String { "\(ticks * rate())" }
}
