import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

private struct AtomicHarness {
    let coordinator: PatchCoordinator
    let runtime: FakeRuntime
    let server: IPCServer
    let root: URL
    let subjects: [URL]

    func stop() {
        runtime.disconnect()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DeliverySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let image: URL

    init(image: URL, failures: Int) {
        self.image = image
        self.remainingFailures = failures
    }

    func deliver() throws -> URL {
        try lock.withLock {
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw EmberError(stage: .transfer, subject: image.lastPathComponent,
                                 reason: "injected transfer failure", recovery: .editAndRetry)
            }
            return image
        }
    }
}

private final class PoisonThenLoadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var replies = 0

    func answer(_ request: LoadPatchRequest) -> LoadPatchResult {
        lock.withLock {
            replies += 1
            if replies == 1 {
                return .failed(stage: .register, message: "injected uncertain load")
            }
            return .loaded(generation: request.generation, durationMs: 1,
                           registered: request.declarations.count, refreshed: nil)
        }
    }
}

private func atomicHarness(
    sources: [String], deliveryFailures: Int = 0
) async throws -> AtomicHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-atomic-batch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let subjects = try sources.enumerated().map { offset, source in
        let url = root.appendingPathComponent("Source\(offset + 1).swift")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let image = root.appendingPathComponent("Patch.dylib")
    try Data().write(to: image)
    let deliveries = DeliverySequence(image: image, failures: deliveryFailures)

    let server = try IPCServer()
    let port = try await server.start()
    let context = BuildContext(
        moduleName: "Fixture", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.atomic-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server,
        workDirectory: root.appendingPathComponent("patches"),
        deliver: { _ in try deliveries.deliver() },
        inventory: ModuleInventory(keys: ["Fixture": sources.count]))
    await coordinator.primeBaselines(from: [root])

    let runtime = FakeRuntime(port: port)
    #expect(await runtime.connect(), "the fake runtime never connected")
    try runtime.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: context.identity,
        moduleName: "Fixture", processId: 1,
        loadedGenerations: [], buildMatchesProcess: true))
    for _ in 0..<200 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.currentSession != nil, "the handshake never completed")
    runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        let result = LoadPatchResult.loaded(
            generation: request.generation, durationMs: 1,
            registered: request.declarations.count, refreshed: nil)
        return ("loadResult", try! JSONEncoder().encode(result))
    }
    return AtomicHarness(coordinator: coordinator, runtime: runtime, server: server,
                         root: root, subjects: subjects)
}

@Test func aFailedMultiFileTransactionRetainsUnsavedSiblingsForRetry() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 1)
    defer { harness.stop() }
    try #"func subject() -> String { helper() + "first" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)

    guard case .rejected(let firstError) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the injected transfer failure did not reject the transaction")
        return
    }
    #expect(firstError.stage == .transfer)

    // The helper's watcher event was consumed by the failed attempt. Saving
    // only its caller must retry the same transaction with that helper still
    // present instead of compiling an incomplete single-file patch.
    try #"func subject() -> String { helper() + "second" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .applied(let generation, _, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the failed transaction lost its unsaved helper")
        return
    }
    #expect(generation == 1)
    #expect(carried == ["helper()"])
    #expect(loadRequests(harness.runtime).count == 1)
}

@Test func revertingTheLastObservableMemberPreservesItsPendingCarry() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 1)
    defer { harness.stop() }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the injected failure did not retain the transaction")
        return
    }

    // Reverting the caller removes the transaction's last replacement, but
    // the helper remains changed on disk and must return to the carry pool.
    try baselines[0].write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the caller revert should leave only a pending carry")
        return
    }

    try #"func subject() -> String { helper() + "retried" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .applied(_, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the caller retry lost the helper whose event was already consumed")
        return
    }
    #expect(declarations == ["subject()"])
    #expect(carried == ["helper()"])
}

@Test func anUnrelatedRefusalDoesNotDiscardATouchedPendingTransaction() async throws {
    let baselines = [
        #"func first() -> String { "old-first" }"#,
        #"func second() -> String { "old-second" }"#,
        #"struct Unsafe { func value() -> Int { 1 } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 1)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-first", with: "pending-first")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try baselines[1].replacingOccurrences(of: "old-second", with: "pending-second")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: Array(harness.subjects.prefix(2))) else {
        Issue.record("the injected failure did not retain the two-file transaction")
        return
    }

    // The next poll refreshes one transaction member but is refused because
    // of a different file. That file must not invalidate the retained unit.
    try baselines[0].replacingOccurrences(of: "old-first", with: "latest-first")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try #"struct Unsafe { var stored = 1; func value() -> Int { 2 } }"#
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .rejected(let refusal) = await harness.coordinator.handle(
        changes: [harness.subjects[0], harness.subjects[2]]) else {
        Issue.record("the unsafe file did not refuse the watcher poll")
        return
    }
    #expect(refusal.stage == .classify)

    // A sibling event must not apply the retained prefix while its blocker is
    // still unsafe. The event is folded into the transaction for the eventual
    // retry instead of being consumed.
    guard case .rejected(let blocked) =
        await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("the pending transaction escaped its unresolved blocker")
        return
    }
    #expect(blocked.stage == .classify)
    #expect(loadRequests(harness.runtime).isEmpty)

    // Safely observing the blocker again should release and retry the complete
    // transaction without requiring another save of either retained file.
    try baselines[2].write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(_, let declarations, _, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the safe blocker event did not release the retained transaction")
        return
    }
    #expect(declarations == ["first()", "second()"])

    let generated = try FileManager.default.contentsOfDirectory(
        at: harness.root.appendingPathComponent("patches"),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Patch_001") && $0.pathExtension == "swift" }
    let generatedSources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(generatedSources.contains { $0.contains("latest-first") })
    #expect(!generatedSources.contains { $0.contains("pending-first") })
}

@Test func aSafeCarrySurvivesWhenItsPendingTransactionBecomesUnsafe() async throws {
    let baselines = [
        #"struct Unsafe { func value() -> Int { 1 } }"#,
        #"func existing() -> String { "existing" }"#,
        #"func subject() -> String { "old" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 1)
    defer { harness.stop() }
    try #"struct Unsafe { func value() -> Int { 2 } }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"first\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: Array(harness.subjects.prefix(2))) else {
        Issue.record("the injected failure did not retain the transaction")
        return
    }

    // Unsafe invalidates the old transaction, while the helper's newly read
    // snapshot remains a valid carry that must wait for Unsafe to be fixed.
    try #"struct Unsafe { var stored = 1; func value() -> Int { 3 } }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"latest\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: Array(harness.subjects.prefix(2))) else {
        Issue.record("the unsafe transaction member was not refused")
        return
    }

    try baselines[0].write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("fixing the carry's blocker should leave it pending")
        return
    }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(_, _, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the safe carry was lost with its invalidated transaction")
        return
    }
    #expect(carried == ["helper()"])
    let generated = try String(contentsOf:
        harness.root.appendingPathComponent("patches/Patch_001_001.swift"),
        encoding: .utf8)
    let secondGenerated = try String(contentsOf:
        harness.root.appendingPathComponent("patches/Patch_001_002.swift"),
        encoding: .utf8)
    #expect(generated.contains("latest") || secondGenerated.contains("latest"))
    #expect(!generated.contains("first") && !secondGenerated.contains("first"))
}

@Test func aLaterSaveJoinsTheFailedTargetUnit() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
        #"func independent() -> String { "old-independent" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 1)
    defer { harness.stop() }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: [harness.subjects[0], harness.subjects[1]]) else {
        Issue.record("the injected failure did not leave a transaction to retry")
        return
    }

    try baselines[2].replacingOccurrences(of: "old-independent", with: "new-independent")
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(let generation, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the later save did not retry the deferred target")
        return
    }
    #expect(generation == 1)
    #expect(declarations == ["subject()", "independent()"])
    #expect(carried == ["helper()"])

    // A target is one conservative retry unit. The successful retry commits
    // every deferred file, so touching an already-applied member is a no-op.
    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the successful target retry left an applied file deferred")
        return
    }
}

@Test func failedSavesInOneModuleMergeIntoOneDeferredTarget() async throws {
    let baselines = [
        #"func first() -> String { "old-first" }"#,
        #"func second() -> String { "old-second" }"#,
        #"func third() -> String { "old-third" }"#,
        #"func fourth() -> String { "old-fourth" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 2)
    defer { harness.stop() }

    for index in 0...1 {
        try baselines[index].replacingOccurrences(of: "old-", with: "new-")
            .write(to: harness.subjects[index], atomically: true, encoding: .utf8)
    }
    guard case .rejected = await harness.coordinator.handle(
        changes: Array(harness.subjects[0...1])) else {
        Issue.record("the first injected failure was not retained")
        return
    }

    for index in 2...3 {
        try baselines[index].replacingOccurrences(of: "old-", with: "new-")
            .write(to: harness.subjects[index], atomically: true, encoding: .utf8)
    }
    guard case .rejected = await harness.coordinator.handle(
        changes: Array(harness.subjects[2...3])) else {
        Issue.record("the second injected failure was not retained")
        return
    }

    let revisedThird = try String(contentsOf: harness.subjects[2], encoding: .utf8)
        .replacingOccurrences(of: "new-third", with: "retried-third")
    try revisedThird.write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(let generation, let declarations, _, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the merged target did not retry")
        return
    }
    #expect(generation == 1)
    #expect(declarations == ["first()", "second()", "third()", "fourth()"])

    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the merged retry did not commit every deferred file")
        return
    }
}

@Test func aLaterHelperRetriesEveryCandidateInItsCompilerContext() async throws {
    let baselines = [
        #"func first() -> String { "old-first" }"#,
        #"func second() -> String { "old-second" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines, deliveryFailures: 2)
    defer { harness.stop() }

    try #"func first() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the first caller was not retained")
        return
    }
    try #"func second() -> String { helper() }"#
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("the second caller was not retained")
        return
    }

    try (baselines[2] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(let generation, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the helper event did not retry the complete target")
        return
    }
    #expect(generation == 1)
    #expect(declarations == ["first()", "second()"])
    #expect(carried == ["helper()"])
}

@Test func anEditWhileUncertainUsesTheLatestDiskContents() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func sibling() -> String { "old-sibling" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    let replies = PoisonThenLoadSequence()
    harness.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        return ("loadResult", try! JSONEncoder().encode(replies.answer(request)))
    }

    try #"func subject() -> String { "first-version" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try #"func sibling() -> String { "new-sibling" }"#
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the uncertain load was not reported")
        return
    }

    try #"func subject() -> String { "second-version" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .sessionUncertain =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the poisoned session accepted another patch")
        return
    }

    await harness.coordinator.sessionDidConnect(processId: 2)
    guard case .applied = await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("the retained transaction did not retry after relaunch")
        return
    }

    let generated = try FileManager.default.contentsOfDirectory(
        at: harness.root.appendingPathComponent("patches"),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Patch_001") && $0.pathExtension == "swift" }
    let generatedSources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(generatedSources.contains { $0.contains("second-version") })
    #expect(!generatedSources.contains { $0.contains("first-version") })
}

private func loadRequests(_ runtime: FakeRuntime) -> [LoadPatchRequest] {
    runtime.envelopes().compactMap { envelope in
        guard envelope.type == "loadPatch" else { return nil }
        return try? envelope.decode(LoadPatchRequest.self)
    }
}

@Test func twoChangedFilesLoadAsOneGeneration() async throws {
    let baselines = [
        #"struct A { func value() -> String { "old-a" } }"#,
        #"struct B { func value() -> String { "old-b" } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-a", with: "new-a")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try baselines[1].replacingOccurrences(of: "old-b", with: "new-b")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)

    guard case .applied(let generation, let declarations, _, _, _, _, _, _) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the batch was not applied")
        return
    }
    #expect(generation == 1)
    #expect(declarations == ["A.value()", "B.value()"])
    let requests = loadRequests(harness.runtime)
    #expect(requests.count == 1)
    #expect(requests.first?.generation == 1)
    #expect(requests.first?.declarations == declarations)
}

@Test func oneUnsafeFilePreventsEveryFileInTheBatchFromLoading() async throws {
    let baselines = [
        #"struct A { func value() -> String { "old-a" } }"#,
        #"struct B { func value() -> String { "old-b" } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-a", with: "new-a")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try #"struct B { var stored = 1; func value() -> String { "new-b" } }"#
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)

    guard case .rejected(let error) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the unsafe batch was not rejected")
        return
    }
    #expect(error.stage == .classify)
    #expect(loadRequests(harness.runtime).isEmpty,
            "a safe prefix of the batch reached the process")

    // Fixing the unsafe file leaves A's edit pending. Its first successful
    // load is still generation one, proving no baseline or generation was
    // committed for the rejected batch.
    try baselines[1].write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .applied(let generation, _, _, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the safe edit was absorbed by the rejected batch")
        return
    }
    #expect(generation == 1)
}

@Test func anUnrelatedSaveCannotApplyTheSafePrefixOfAStillRefusedBatch() async throws {
    let baselines = [
        #"struct A { func value() -> String { "old-a" } }"#,
        #"struct B { func value() -> String { "old-b" } }"#,
        #"struct C { func value() -> String { "old-c" } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-a", with: "new-a")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try #"struct B { var stored = 1; func value() -> String { "new-b" } }"#
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: [harness.subjects[0], harness.subjects[1]]) else {
        Issue.record("the unsafe batch was not rejected")
        return
    }

    // B is deliberately still unsafe. The simpler target-wide retry model
    // prevents a later save in the same target from bypassing that blocker.
    try baselines[2].replacingOccurrences(of: "old-c", with: "new-c")
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("the later save bypassed the target's unresolved blocker")
        return
    }
    #expect(loadRequests(harness.runtime).isEmpty)

    // Observing the blocker become safe retries every deferred body edit.
    try baselines[1].write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .applied(_, let declarations, _, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("fixing the blocker did not retry the deferred target")
        return
    }
    #expect(declarations == ["A.value()", "C.value()"])
    #expect(loadRequests(harness.runtime).count == 1)
}

@Test func aSafeAdditionFromARefusedBatchRemainsAvailableForRetry() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
        #"struct Unsafe { func value() -> Int { 1 } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    try #"struct Unsafe { var stored = 1; func value() -> Int { 2 } }"#
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)

    guard case .rejected = await harness.coordinator.handle(
        changes: [harness.subjects[1], harness.subjects[2]]) else {
        Issue.record("the unsafe batch was not rejected")
        return
    }

    // The watcher consumed both save events. Fixing only the unsafe file must
    // not lose the safe helper whose file will not emit another event.
    try baselines[2].write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("fixing the unsafe file should leave the helper waiting for a caller")
        return
    }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)

    guard case .applied(_, _, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the next independent patch did not load")
        return
    }
    #expect(carried == ["helper()"])
}

@Test func aCarryCannotEscapeARefusedBatchBeforeItsBlockerIsFixed() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
        #"struct Unsafe { func value() -> Int { 1 } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    try #"struct Unsafe { var stored = 1; func value() -> Int { 2 } }"#
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: [harness.subjects[1], harness.subjects[2]]) else {
        Issue.record("the unsafe batch was not rejected")
        return
    }

    // The blocker is deliberately unchanged. A later body edit in the same
    // target cannot bypass it or consume the helper by itself.
    try #"func subject() -> String { "independent" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the body edit bypassed the target's unresolved blocker")
        return
    }
    #expect(loadRequests(harness.runtime).isEmpty)

    try baselines[2].write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .applied(_, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[2]) else {
        Issue.record("fixing the blocker did not retry the complete target")
        return
    }
    #expect(declarations == ["subject()"])
    #expect(carried == ["helper()"])
}

@Test func observingARevertedAdditionRemovesItFromTheDeferredTarget() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
        #"struct Unsafe { func value() -> Int { 1 } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    try #"struct Unsafe { var stored = 1; func value() -> Int { 2 } }"#
        .write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .rejected = await harness.coordinator.handle(
        changes: [harness.subjects[1], harness.subjects[2]]) else {
        Issue.record("the unsafe batch was not rejected")
        return
    }

    try baselines[1].write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    try baselines[2].write(to: harness.subjects[2], atomically: true, encoding: .utf8)
    guard case .ignored = await harness.coordinator.handle(
        changes: [harness.subjects[1], harness.subjects[2]]) else {
        Issue.record("the observed reverts should clear the deferred target")
        return
    }
    try #"func subject() -> String { "new" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .applied(_, _, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the independent patch did not load")
        return
    }
    #expect(carried.isEmpty)
}

@Test func anUnreadableFileRejectsTheCompleteBatch() async throws {
    let baselines = [
        #"struct A { func value() -> String { "old-a" } }"#,
        #"struct B { func value() -> String { "old-b" } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-a", with: "new-a")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: harness.subjects[1])

    guard case .rejected(let error) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the incomplete batch was not rejected")
        return
    }
    #expect(error.stage == .watch)
    #expect(error.recovery == .editAndRetry)
    #expect(loadRequests(harness.runtime).isEmpty)
}

private final class ReplySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UInt64] = []

    func answer(_ request: LoadPatchRequest) -> LoadPatchResult {
        lock.withLock {
            generations.append(request.generation)
            if generations.count == 1 {
                return .rejected(reason: "not ready")
            }
            return .loaded(generation: request.generation, durationMs: 1,
                           registered: request.declarations.count, refreshed: nil)
        }
    }

    var seenGenerations: [UInt64] { lock.withLock { generations } }
}

@Test func aDeclinedAtomicLoadCommitsNoFileBaseline() async throws {
    let baselines = [
        #"struct A { func value() -> String { "old-a" } }"#,
        #"struct B { func value() -> String { "old-b" } }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try baselines[0].replacingOccurrences(of: "old-a", with: "new-a")
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try baselines[1].replacingOccurrences(of: "old-b", with: "new-b")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)

    let replies = ReplySequence()
    harness.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        return ("loadResult", try! JSONEncoder().encode(replies.answer(request)))
    }

    guard case .rejected = await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the runtime refusal was not surfaced")
        return
    }
    guard case .applied(let generation, _, _, _, _, _, _, _) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the unchanged batch was not retried in full")
        return
    }
    #expect(generation == 1)
    #expect(replies.seenGenerations == [1, 1])
}

@Test func aCrossFileCarriedHelperSurvivesLaterGenerations() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)

    guard case .applied(let first, _, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the cross-file helper did not land")
        return
    }
    #expect(first == 1)
    #expect(carried == ["helper()"])

    try #"func subject() -> String { helper() + "!" }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .applied(let second, _, let carriedAgain, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the next generation lost the other file's helper")
        return
    }
    #expect(second == 2)
    #expect(carriedAgain == ["helper()"])

    let generated = try FileManager.default.contentsOfDirectory(
        at: harness.root.appendingPathComponent("patches"),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Patch_002_") && $0.pathExtension == "swift" }
    #expect(generated.count == 2)
    let sources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(sources.contains { $0.contains("func helper() -> String") })
}

@Test func editingACrossFileCarriedHelperStartsANewGeneration() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }
    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    try (baselines[1] + "\nfunc helper() -> String { \"first\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .applied(let first, _, _, _, _, _, _, _) =
        await harness.coordinator.handle(changes: harness.subjects) else {
        Issue.record("the initial cross-file patch did not load")
        return
    }
    #expect(first == 1)

    let revised = try String(contentsOf: harness.subjects[1], encoding: .utf8)
        .replacingOccurrences(of: "first", with: "second")
    try revised.write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .applied(let second, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("editing only the carried helper was ignored")
        return
    }
    #expect(second == 2)
    #expect(declarations == ["subject()"])
    #expect(carried == ["helper()"])
    #expect(loadRequests(harness.runtime).map(\.generation) == [1, 2])
}

@Test func anEarlierCarryOnlySaveJoinsTheLaterCallingFile() async throws {
    let baselines = [
        #"func subject() -> String { "old" }"#,
        #"func existing() -> String { "existing" }"#,
    ]
    let harness = try await atomicHarness(sources: baselines)
    defer { harness.stop() }

    try (baselines[1] + "\nfunc helper() -> String { \"new\" }\n")
        .write(to: harness.subjects[1], atomically: true, encoding: .utf8)
    guard case .ignored = await harness.coordinator.handle(change: harness.subjects[1]) else {
        Issue.record("a carried-only save should wait for an observable caller")
        return
    }
    #expect(loadRequests(harness.runtime).isEmpty)

    try #"func subject() -> String { helper() }"#
        .write(to: harness.subjects[0], atomically: true, encoding: .utf8)
    guard case .applied(let generation, let declarations, let carried, _, _, _, _, _) =
        await harness.coordinator.handle(change: harness.subjects[0]) else {
        Issue.record("the pending helper did not join its caller")
        return
    }
    #expect(generation == 1)
    #expect(declarations == ["subject()"])
    #expect(carried == ["helper()"])
    #expect(loadRequests(harness.runtime).count == 1)
}

private final class DeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries = 0

    func mark() { lock.withLock { deliveries += 1 } }
    var count: Int { lock.withLock { deliveries } }
}

@Test func aCrossContextRefusalRefreshesEachPendingTransaction() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-atomic-pending-contexts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0".write(
        to: root.appendingPathComponent("Package.swift"),
        atomically: true, encoding: .utf8)

    var sourcesByModule: [[URL]] = []
    for module in ["FeatureA", "FeatureB"] {
        let directory = root.appendingPathComponent("Sources/\(module)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let sources = try ["first", "second", "third"].map { name in
            let url = directory.appendingPathComponent("\(name).swift")
            try "func \(name)() -> String { \"old-\(module)-\(name)\" }"
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        sourcesByModule.append(sources)
    }

    let server = try IPCServer()
    defer { server.stop() }
    let patches = root.appendingPathComponent("patches")
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: sourcesByModule.map { $0[0].deletingLastPathComponent().path },
        bundleIdentifier: "dev.swift-ember.atomic-pending-context-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: patches,
        deliver: { image in image },
        inventory: ModuleInventory(keys: ["FeatureA": 3, "FeatureB": 3]))
    await coordinator.primeBaselines(
        from: sourcesByModule.map { $0[0].deletingLastPathComponent() })

    // Create one failed two-file unit in each compiler context. With no
    // runtime connected, both reach LOAD and retain their deferred URLs.
    for sources in sourcesByModule {
        for source in sources.prefix(2) {
            let current = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "old-", with: "pending-")
            try current.write(to: source, atomically: true, encoding: .utf8)
        }
        guard case .rejected(let error) = await coordinator.handle(
            changes: Array(sources.prefix(2))),
              error.stage == .load else {
            Issue.record("the module transaction did not become pending")
            return
        }
    }

    // One later poll updates a member of each unit. They compile independently
    // into one image, and both targets must observe the latest disk contents.
    for sources in sourcesByModule {
        let current = try String(contentsOf: sources[0], encoding: .utf8)
            .replacingOccurrences(of: "pending-", with: "latest-")
        try current.write(to: sources[0], atomically: true, encoding: .utf8)
    }
    let newFeatureASource = try String(contentsOf: sourcesByModule[0][2], encoding: .utf8)
        .replacingOccurrences(of: "old-", with: "latest-")
    try newFeatureASource.write(
        to: sourcesByModule[0][2], atomically: true, encoding: .utf8)
    guard case .rejected(let refusal) = await coordinator.handle(
        changes: [sourcesByModule[0][0], sourcesByModule[0][2], sourcesByModule[1][0]]) else {
        Issue.record("the cross-module retry unexpectedly loaded without a runtime")
        return
    }
    #expect(refusal.stage == .load)

    // A sibling event retries FeatureA. The generated unit must contain the
    // latest first-file body rather than the contents from its first failure.
    guard case .rejected = await coordinator.handle(change: sourcesByModule[0][1]) else {
        Issue.record("the refreshed transaction did not retry")
        return
    }
    let generated = try FileManager.default.contentsOfDirectory(
        at: patches, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Patch_001") && $0.pathExtension == "swift" }
    let generatedSources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(generatedSources.contains { $0.contains("latest-FeatureA-first") })
    #expect(!generatedSources.contains { $0.contains("pending-FeatureA-first") })
    #expect(generatedSources.contains { $0.contains("latest-FeatureA-third") })
}

@Test func aNewContextDoesNotDiscardThePendingContextItArrivesWith() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-atomic-new-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let featureA = root.appendingPathComponent("Sources/FeatureA", isDirectory: true)
    let featureB = root.appendingPathComponent("Sources/FeatureB", isDirectory: true)
    try FileManager.default.createDirectory(
        at: featureA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: featureB, withIntermediateDirectories: true)
    let first = featureA.appendingPathComponent("First.swift")
    let second = featureA.appendingPathComponent("Second.swift")
    let other = featureB.appendingPathComponent("Other.swift")
    try #"func first() -> String { "old-a-first" }"#
        .write(to: first, atomically: true, encoding: .utf8)
    try #"func second() -> String { "old-a-second" }"#
        .write(to: second, atomically: true, encoding: .utf8)
    try #"func other() -> String { "old-b-other" }"#
        .write(to: other, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    defer { server.stop() }
    let patches = root.appendingPathComponent("patches")
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [featureA.path, featureB.path],
        bundleIdentifier: "dev.swift-ember.atomic-new-context-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: patches,
        deliver: { image in image },
        inventory: ModuleInventory(keys: ["FeatureA": 2, "FeatureB": 1]))
    await coordinator.primeBaselines(from: [featureA, featureB])

    try #"func first() -> String { "pending-a-first" }"#
        .write(to: first, atomically: true, encoding: .utf8)
    try #"func second() -> String { "pending-a-second" }"#
        .write(to: second, atomically: true, encoding: .utf8)
    guard case .rejected(let pendingError) = await coordinator.handle(
        changes: [first, second]), pendingError.stage == .load else {
        Issue.record("the FeatureA transaction did not become pending")
        return
    }

    // This poll touches FeatureA's retained unit and introduces its first
    // FeatureB edit. A failed load of the combined image must not consume
    // either module's latest snapshot or FeatureA's unsaved sibling.
    try #"func first() -> String { "latest-a-first" }"#
        .write(to: first, atomically: true, encoding: .utf8)
    try #"func other() -> String { "latest-b-other" }"#
        .write(to: other, atomically: true, encoding: .utf8)
    guard case .rejected(let refusal) = await coordinator.handle(changes: [first, other]) else {
        Issue.record("the mixed compiler contexts unexpectedly loaded without a runtime")
        return
    }
    #expect(refusal.stage == .load)

    guard case .rejected(let retryError) = await coordinator.handle(change: second),
          retryError.stage == .load else {
        Issue.record("the retained FeatureA transaction did not retry as one unit")
        return
    }
    let generated = [
        patches.appendingPathComponent("Patch_001_001.swift"),
        patches.appendingPathComponent("Patch_001_002.swift"),
    ]
    let generatedSources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(generatedSources.contains { $0.contains("latest-a-first") })
    #expect(generatedSources.contains { $0.contains("pending-a-second") })
}

@Test func aCrossModuleBatchProducesOneImageBeforeAnyLoadIsAttempted() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-atomic-modules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0".write(
        to: root.appendingPathComponent("Package.swift"),
        atomically: true, encoding: .utf8)
    let sources = try ["FeatureA", "FeatureB"].map { module in
        let directory = root.appendingPathComponent("Sources/\(module)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Subject.swift")
        try "func value() -> String { \"old-\(module)\" }"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: sources.map { $0.deletingLastPathComponent().path },
        bundleIdentifier: "dev.swift-ember.atomic-module-tests")
    let delivery = DeliveryProbe()
    let coordinator = PatchCoordinator(
        context: context, server: server,
        workDirectory: root.appendingPathComponent("patches"),
        deliver: { image in delivery.mark(); return image },
        inventory: ModuleInventory(keys: ["FeatureA": 1, "FeatureB": 1]))
    await coordinator.primeBaselines(
        from: sources.map { $0.deletingLastPathComponent() })
    for source in sources {
        let current = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "old-", with: "new-")
        try current.write(to: source, atomically: true, encoding: .utf8)
    }

    guard case .rejected(let error) = await coordinator.handle(changes: sources) else {
        Issue.record("the cross-module batch unexpectedly loaded without a runtime")
        return
    }
    #expect(error.stage == .load)
    #expect(delivery.count == 1)
    let generated = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("patches"), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("Patch_001") && $0.pathExtension == "swift" }
    #expect(generated.count == 2)
    let generatedSources = try generated.map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(generatedSources.contains { $0.contains("@testable import FeatureA") })
    #expect(generatedSources.contains { $0.contains("@testable import FeatureB") })

    // This is a later watcher poll, not the second half of the rejected one.
    // It should reach LOAD on its own instead of being rejoined with FeatureB
    // and refused again as a cross-module batch.
    guard case .rejected(let retryError) = await coordinator.handle(change: sources[0]) else {
        Issue.record("the individual retry unexpectedly loaded without a runtime")
        return
    }
    #expect(retryError.stage == .load)
    #expect(delivery.count == 2)
}

@Test func aLaterModuleCompileFailureDeliversNoPartialImage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-atomic-module-compile-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0".write(
        to: root.appendingPathComponent("Package.swift"),
        atomically: true, encoding: .utf8)

    let sources = try ["FeatureA", "FeatureB"].map { module in
        let directory = root.appendingPathComponent("Sources/\(module)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Subject.swift")
        try "func value() -> String { \"old-\(module)\" }"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    let compiler = root.appendingPathComponent("compiler.sh")
    try """
        #!/bin/sh
        case "$*" in
          *Patch_001_002*) echo "intentional second-module failure" >&2; exit 1 ;;
          *) exit 0 ;;
        esac
        """.write(to: compiler, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: compiler.path)

    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: compiler.path,
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: sources.map { $0.deletingLastPathComponent().path },
        bundleIdentifier: "dev.swift-ember.atomic-module-compile-failure-tests")
    let delivery = DeliveryProbe()
    let coordinator = PatchCoordinator(
        context: context, server: server,
        workDirectory: root.appendingPathComponent("patches"),
        deliver: { image in delivery.mark(); return image },
        inventory: ModuleInventory(keys: ["FeatureA": 1, "FeatureB": 1]))
    await coordinator.primeBaselines(from: sources.map { $0.deletingLastPathComponent() })
    for source in sources {
        let current = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "old-", with: "new-")
        try current.write(to: source, atomically: true, encoding: .utf8)
    }

    guard case .rejected(let error) = await coordinator.handle(changes: sources) else {
        Issue.record("the failed compiler batch was not rejected")
        return
    }
    #expect(error.stage == .compile)
    #expect(error.reason.contains("intentional second-module failure"))
    #expect(delivery.count == 0)
}
