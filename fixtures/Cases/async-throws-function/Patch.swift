@testable import Fixture

@_dynamicReplacement(for: fetch())
func patched_fetch() async throws -> String { "new" }
