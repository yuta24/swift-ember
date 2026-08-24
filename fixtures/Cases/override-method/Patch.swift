@testable import Fixture

extension CurrencyFormatter {
    @_dynamicReplacement(for: format(_:))
    func patched_format(_ value: Int) -> String {
        calls += 1
        return "new(\(value))"
    }
}
