@testable import Fixture

extension Session {
    @_dynamicReplacement(for: summary())
    func patched_summary() -> String { "new(hits=\(hits))" }
}
