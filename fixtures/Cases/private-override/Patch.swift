@_private(sourceFile: "App.swift") @testable import Fixture

extension Sub {
    @_dynamicReplacement(for: tag())
    func patched_tag() -> String { "sub-new" }
}
