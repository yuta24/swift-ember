import Foundation
import Testing
import EmberCore
@testable import EmberCLI

@Test func implicitSimulatorSelectionRecordsTheUDIDAndWarnsWhenAmbiguous() throws {
    let selection = try SimulatorSelection.select(from: Data("""
        {"devices":{"new":[{"udid":"B","state":"Booted"},{"udid":"0","state":"Shutdown"}],
                    "old":[{"udid":"A","state":"Booted"}]}}
        """.utf8))
    #expect(selection.identifier == "A")
    #expect(selection.warning?.contains("Selected A") == true)
    #expect(selection.warning?.contains("--simulator") == true)

    let onlyBooted = try SimulatorSelection.select(from: Data("""
        {"devices":{"new":[{"udid":"B","state":"Booted"},{"udid":"A","state":"Shutdown"}]}}
        """.utf8))
    #expect(onlyBooted.identifier == "B")
    #expect(onlyBooted.warning == nil)

    #expect(throws: EmberError.self) {
        try SimulatorSelection.select(from: Data(#"{"devices":{"new":[]}}"#.utf8))
    }
}

@Test func aSimulatorAppRejectsAnotherOwnerAndCanBeClaimedAfterRelease() throws {
    let simulator = UUID().uuidString
    let bundle = "dev.swift-ember.tests"
    let first = SimulatorOwnership.Owner(pid: 123, emberRoot: "/worktree-a/.ember", log: "/worktree-a/.ember/logs/app.log")
    let second = SimulatorOwnership.Owner(pid: 456, emberRoot: "/worktree-b/.ember", log: "/worktree-b/.ember/logs/app.log")
    do {
        let owner = try SimulatorOwnership.acquire(simulator: simulator, bundle: bundle, owner: first)
        defer { withExtendedLifetime(owner) {} }

        let conflict = try #require(throws: SimulatorOwnership.Conflict.self) {
            try SimulatorOwnership.acquire(simulator: simulator.lowercased(), bundle: bundle, owner: second)
        }
        #expect(conflict.owner?.pid == first.pid)
        #expect(conflict.description.contains(try #require(first.emberRoot)))
        #expect(conflict.description.contains(try #require(first.log)))

        _ = try SimulatorOwnership.acquire(simulator: UUID().uuidString, bundle: bundle, owner: second)
        _ = try SimulatorOwnership.acquire(simulator: simulator, bundle: bundle + ".other", owner: second)
    }
    _ = try SimulatorOwnership.acquire(simulator: simulator, bundle: bundle, owner: second)
}
