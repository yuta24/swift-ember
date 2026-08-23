@testable import Fixture

@_dynamicReplacement(for: describe(_:))
func patched_describe<T: CustomStringConvertible>(_ value: T) -> String { "new(\(value))" }
