@testable import Fixture

@_dynamicReplacement(for: secret())
func patched_secret() -> String { "new" }
