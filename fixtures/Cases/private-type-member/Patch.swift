@_private(sourceFile: "App.swift") @testable import Fixture

extension Helper {
    @_dynamicReplacement(for: scale(_:))
    func patched_scale(_ v: Int) -> Int { v * 10 }
}
