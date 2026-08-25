@_private(sourceFile: "App.swift") @testable import Fixture

extension Wallet {
    @_dynamicReplacement(for: label())
    func patched_label() -> String { "\(symbol)\(cents / 100).\(cents % 100)" }
}
