@testable import Fixture

@_dynamicReplacement(for: subject())
func patched_subject() -> String { "new" }
