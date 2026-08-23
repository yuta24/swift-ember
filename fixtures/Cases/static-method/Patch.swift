@testable import Fixture

extension Registry {
    @_dynamicReplacement(for: lookup())
    static func patched_lookup() -> String { "new" }
}
