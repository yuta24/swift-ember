@testable import Fixture

extension Describable {
    @_dynamicReplacement(for: describe())
    func patched_describe() -> String { "new" }
}
