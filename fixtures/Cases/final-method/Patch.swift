@testable import Fixture

extension Sealed {
    @_dynamicReplacement(for: run())
    func patched_run() -> String { "new" }
}
