@testable import Fixture

@_dynamicReplacement(for: load())
func patched_load() async -> String { "new" }
