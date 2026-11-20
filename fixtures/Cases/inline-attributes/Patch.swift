@testable import Fixture

@_dynamicReplacement(for: alwaysInline(_:))
@inline(__always)
func patchedAlwaysInline<T>(_ value: T) -> String { "new(\(value))" }

@_dynamicReplacement(for: neverInline(_:))
@inline(never)
func patchedNeverInline<T>(_ value: T) -> String { "new(\(value))" }
