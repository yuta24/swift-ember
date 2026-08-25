@_private(sourceFile: "App.swift") @testable import Fixture

@_dynamicReplacement(for: discount(_:))
private func patched_discount(_ cents: Int) -> Int { cents - 100 }
