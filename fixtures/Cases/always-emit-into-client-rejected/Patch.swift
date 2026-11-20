@testable import Fixture

@_dynamicReplacement(for: emittedIntoClient())
func patchedEmittedIntoClient() -> String { "new" }
