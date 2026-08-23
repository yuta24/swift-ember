@testable import Fixture

extension Counter {
    @_dynamicReplacement(for: label())
    func patched_label() -> String { "new" }
}
