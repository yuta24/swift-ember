public func libraryGeneric<T>(_ value: T) -> String { "old(\(value))" }

@usableFromInline
func helper() -> String { "old-helper" }

@inlinable
public func libraryInlinable() -> String { "new-body/" + helper() }

// Force the app to ask the dylib to execute its current body.
@inline(never)
public func callInlinableInLibrary() -> String { libraryInlinable() }
