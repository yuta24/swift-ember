@_private(sourceFile: "App.swift") @testable import Fixture

@_dynamicReplacement(for: secret())
private func patched_secret() -> String { "new" }
