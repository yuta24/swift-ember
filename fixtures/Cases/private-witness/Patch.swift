@_private(sourceFile: "App.swift") @testable import Fixture

extension Always {
    @_dynamicReplacement(for: check())
    func patched_check() -> String { "new" }
}
