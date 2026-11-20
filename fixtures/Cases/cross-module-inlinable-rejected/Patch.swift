@testable import FixtureDependency

@_dynamicReplacement(for: libraryInlinable())
func patchedLibraryInlinable() -> String { "new-body/" + helper() }
