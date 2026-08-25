@_private(sourceFile: "App.swift") @testable import Fixture

@_dynamicReplacement(for: base())
private func patched_base() -> Int { 20 }
