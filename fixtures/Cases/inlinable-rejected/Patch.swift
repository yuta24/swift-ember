@testable import Fixture

@_dynamicReplacement(for: helper())
func patched_helper() -> String { "new" }
