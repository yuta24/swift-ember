import Foundation
import Darwin
import Testing
import EmberCore
@testable import EmberCLI

@Test func automaticRebuildIsLimitedToTierCClassification() {
    let tierC = EmberError(
        stage: .classify, subject: "Feature.swift",
        reason: "stored property changed", recovery: .rebuild)
    let loadRejection = EmberError(
        stage: .load, subject: "patch.dylib",
        reason: "runtime rejected the image", recovery: .rebuild)
    let configuration = EmberError(
        stage: .classify, subject: "Feature.swift",
        reason: "module has no replacement keys", recovery: .configure)

    #expect(RebuildCommand.shouldRun(for: tierC))
    #expect(!RebuildCommand.shouldRun(for: loadRejection))
    #expect(!RebuildCommand.shouldRun(for: configuration))
}

@Test func rebuildCommandUsesItsDirectoryAndMarksItsEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await RebuildCommand.Runner().run(
        "pwd > working-directory.txt; printf '%s' \"$SWIFT_EMBER_REBUILD\" > environment.txt",
        in: root)

    let directory = try String(
        contentsOf: root.appendingPathComponent("working-directory.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let environment = try String(
        contentsOf: root.appendingPathComponent("environment.txt"), encoding: .utf8)
    #expect(URL(fileURLWithPath: directory).lastPathComponent == root.lastPathComponent)
    #expect(environment == "1")
}

@Test func rebuildCommandReportsANonzeroExit() async {
    do {
        try await RebuildCommand.Runner().run(
            "exit 23", in: FileManager.default.temporaryDirectory)
        Issue.record("a failed rebuild command was accepted")
    } catch let failure as RebuildCommand.Failure {
        #expect(failure.status == 23)
        #expect(failure.description.contains("exit 23"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func rebuildCancellationStopsTheWholeCommandGroup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let childFile = root.appendingPathComponent("child-pid.txt")
    let runner = RebuildCommand.Runner()
    let task = Task {
        try await runner.run(
            "trap 'printf term > terminated.txt' TERM; sleep 30 & echo $! > child-pid.txt; wait",
            in: root)
    }
    for _ in 0..<40 where !FileManager.default.fileExists(atPath: childFile.path) {
        try await Task.sleep(for: .milliseconds(25))
    }
    let childPID = try #require(Int32(
        String(contentsOf: childFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    let start = Date()
    runner.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 5)

    var childExists = true
    for _ in 0..<40 {
        errno = 0
        childExists = kill(childPID, 0) == 0 || errno != ESRCH
        if !childExists { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!childExists, "the rebuild command's child process survived cancellation")
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("terminated.txt").path),
        "the rebuild shell did not receive SIGTERM before the forced-kill deadline")
}

@Test func rebuildCancellationRemainsVisibleAfterTheCommandExits() async throws {
    let runner = RebuildCommand.Runner()
    try await runner.run("true", in: FileManager.default.temporaryDirectory)

    runner.cancel()

    #expect(throws: CancellationError.self) {
        try runner.throwIfStopping()
    }
}
