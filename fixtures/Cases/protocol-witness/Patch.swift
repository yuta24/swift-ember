@testable import Fixture

extension EnglishGreeter {
    @_dynamicReplacement(for: greet())
    func patched_greet() -> String { "new" }
}
