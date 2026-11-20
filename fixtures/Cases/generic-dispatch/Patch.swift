@testable import Fixture

extension Box where T: Equatable {
    @_dynamicReplacement(for: matches(_:))
    func patchedMatches(_ other: T) -> String { "new(\(value == other))" }

    @_dynamicReplacement(for: score())
    func patchedScore() -> String { "new(\(value == value))" }
}

@_dynamicReplacement(for: describe(_:))
func patchedDescribe<T>(_ value: T) -> String { "new(\(value))" }
