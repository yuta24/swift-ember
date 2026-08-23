@testable import Fixture

@_dynamicReplacement(for: risky())
func patched_risky() throws -> String { "new" }
