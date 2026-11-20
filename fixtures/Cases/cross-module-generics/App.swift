import FixtureDependency

func probe() async throws -> [String] {
    [
        "generic: \(libraryGeneric(7))",
        "inlinable from app: \(libraryInlinable())",
        "inlinable from library: \(callInlinableInLibrary())",
    ]
}
