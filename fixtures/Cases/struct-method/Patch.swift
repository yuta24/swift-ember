@testable import Fixture

extension Price {
    @_dynamicReplacement(for: formatted())
    func patched_formatted() -> String { "new(\(value))" }
}
