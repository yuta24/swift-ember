@testable import Fixture

@_dynamicReplacement(for: shortcut())
func patched_shortcut() -> String { "new" }
