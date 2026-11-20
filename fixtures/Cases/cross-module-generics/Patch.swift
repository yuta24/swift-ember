@testable import FixtureDependency

@_dynamicReplacement(for: libraryGeneric(_:))
public func patchedLibraryGeneric<T>(_ value: T) -> String { "new(\(value))" }

@_dynamicReplacement(for: helper())
@usableFromInline
func patchedHelper() -> String { "new-helper" }
