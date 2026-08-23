@testable import Fixture

extension Kind {
    @_dynamicReplacement(for: name())
    func patched_name() -> String { "new(\(self))" }
}
