import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

@Test func aRebuildResetsDeferredChangesAndAdoptsTheNewSourceBaseline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-reset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("Subject.swift")
    let original = "struct Subject { func value() -> Int { 1 } }"
    let rebuilt = "struct Subject { var stored = 2; func value() -> Int { stored } }"
    try original.write(to: source, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.rebuild-reset-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent("patches"),
        deliver: { $0 }, inventory: ModuleInventory(keys: ["App": 1]))
    await coordinator.primeBaselines(from: [root])

    try rebuilt.write(to: source, atomically: true, encoding: .utf8)
    guard case .rejected(let structural) = await coordinator.handle(change: source) else {
        Issue.record("the structural edit was not rejected before the rebuild")
        return
    }
    #expect(structural.recovery == .rebuild)

    // The configured command has rebuilt the binary from `rebuilt`. The next
    // body-only edit must be compared with that source, not with the pre-build
    // layout or the deferred refusal.
    let snapshot = try SourceSnapshot.capture(from: [root])
    // An edit racing the final reset must remain different from the exact
    // source snapshot that the rebuild was proven to contain.
    try rebuilt.replacingOccurrences(of: "{ stored }", with: "{ stored + 1 }")
        .write(to: source, atomically: true, encoding: .utf8)
    await coordinator.resetAfterRebuild(to: snapshot)
    #expect(await coordinator.hasBaseline(for: source))

    guard case .rejected(let retry) = await coordinator.handle(change: source) else {
        Issue.record("the body edit unexpectedly loaded without a runtime")
        return
    }
    #expect(retry.stage == .load)
}

@Test func aRemovedFileIsAbsentFromTheRebuiltBaseline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-removal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Removed.swift")
    try "func old() {}".write(to: source, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx", appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [], sourceRoots: [root.path],
        bundleIdentifier: "dev.swift-ember.rebuild-removal-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent("patches"),
        inventory: ModuleInventory(keys: ["App": 1]))
    await coordinator.primeBaselines(from: [root])
    #expect(await coordinator.hasBaseline(for: source))

    try FileManager.default.removeItem(at: source)
    let snapshot = try SourceSnapshot.capture(from: [root])
    await coordinator.resetAfterRebuild(to: snapshot)
    #expect(!(await coordinator.hasBaseline(for: source)))
}

@Test func removingANeverLoadedAdditionDoesNotBlockItsTarget() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-pending-removal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let subject = root.appendingPathComponent("Subject.swift")
    let addition = root.appendingPathComponent("Transient.swift")
    try "struct Subject { func value() -> Int { 1 } }".write(
        to: subject, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.pending-removal-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent("patches"),
        deliver: { $0 }, inventory: ModuleInventory(keys: ["App": 1]))
    await coordinator.primeBaselines(from: [root])

    try "func transient() -> Int { 1 }".write(
        to: addition, atomically: true, encoding: .utf8)
    guard case .ignored = await coordinator.handle(change: addition) else {
        Issue.record("the carry-only addition was not retained as pending")
        return
    }

    try FileManager.default.removeItem(at: addition)
    await coordinator.discardRemovedSourceWithoutBaseline(addition)

    try "struct Subject { func value() -> Int { 2 } }".write(
        to: subject, atomically: true, encoding: .utf8)
    guard case .rejected(let result) = await coordinator.handle(change: subject) else {
        Issue.record("the sibling edit did not reach the runtime load stage")
        return
    }
    #expect(result.stage == .load)
    #expect(result.subject != addition.lastPathComponent)
}

@Test func rebuildRecoveryRejectsAHelloThatProvedThePreviousUUIDs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-proof-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let server = try IPCServer()
    defer { server.stop() }
    _ = try await server.start()
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [], sourceRoots: [root.path],
        bundleIdentifier: "dev.swift-ember.rebuild-proof-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent("patches"),
        inventory: ModuleInventory(keys: ["App": 1]), buildUUIDs: ["new-uuid"])

    let stale = FakeRuntime(port: server.port)
    await stale.connect()
    defer { stale.disconnect() }
    try stale.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: context.identity, moduleName: "App",
        processId: 20, loadedGenerations: [], expectedBuildUUIDs: ["old-uuid"],
        buildMatchesProcess: true))
    for _ in 0..<100 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await coordinator.currentBuildProcessID() == nil)

    let current = FakeRuntime(port: server.port)
    await current.connect()
    defer { current.disconnect() }
    try current.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: context.identity, moduleName: "App",
        processId: 21, loadedGenerations: [], expectedBuildUUIDs: ["new-uuid"],
        buildMatchesProcess: true))
    for _ in 0..<100 where server.currentSession?.hello.processId != 21 {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await coordinator.currentBuildProcessID() == 21)
}

@Test func aStaleReconnectCannotSupersedeTheCurrentBuild() async throws {
    let server = try IPCServer()
    defer { server.stop() }
    server.shouldAcceptHello = { hello in
        hello.buildIdentity == "current-build"
            && hello.expectedBuildUUIDs == ["current-uuid"]
            && hello.buildMatchesProcess
    }
    _ = try await server.start()

    let current = FakeRuntime(port: server.port)
    await current.connect()
    defer { current.disconnect() }
    try current.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "current-build", moduleName: "App",
        processId: 21, loadedGenerations: [], expectedBuildUUIDs: ["current-uuid"],
        buildMatchesProcess: true))
    for _ in 0..<100 where server.currentSession?.hello.processId != 21 {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.currentSession?.hello.processId == 21)

    let stale = FakeRuntime(port: server.port)
    await stale.connect()
    defer { stale.disconnect() }
    try stale.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "current-build", moduleName: "App",
        processId: 20, loadedGenerations: [], expectedBuildUUIDs: ["current-uuid"],
        buildMatchesProcess: false))
    let warning = try #require(await stale.waitForEnvelope())
    #expect(warning.type == "helloRejected")

    #expect(server.currentSession?.hello.processId == 21,
            "a stale process evicted the runtime that proved the current build")

    server.disconnectCurrentSession()
    #expect(await stale.waitForDisconnect(),
            "a session refresh left the quarantined runtime on its stale hello")
}

@Test func rebuildSnapshotsIncludeExcludedSafetySourcesAndFailAsAWhole() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-rebuild-snapshot-\(UUID().uuidString)", isDirectory: true)
    let excludedRoot = root.appendingPathComponent("Generated", isDirectory: true)
    try FileManager.default.createDirectory(at: excludedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let watched = root.appendingPathComponent("Watched.swift")
    let excluded = excludedRoot.appendingPathComponent("Excluded.swift")
    try "func watched() {}".write(to: watched, atomically: true, encoding: .utf8)
    try "func excluded() {}".write(to: excluded, atomically: true, encoding: .utf8)

    let snapshot = try SourceSnapshot.capture(
        from: [root], excluding: SourcePathFilter(excluding: [excludedRoot]))
    #expect(snapshot.watched[watched.standardizedFileURL] == "func watched() {}")
    #expect(snapshot.excluded[excluded.standardizedFileURL] == "func excluded() {}")

    let missing = root.appendingPathComponent("Missing", isDirectory: true)
    #expect(throws: FileWatcher.ScanFailure.self) {
        _ = try SourceSnapshot.capture(from: [root, missing])
    }
}
