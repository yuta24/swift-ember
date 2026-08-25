import Foundation
import Testing
import SpliceCore
@testable import SpliceDaemon

/// DESIGN.md section 17: a load or registration failure may leave the process
/// in a state nobody can describe, and the session should say so rather than
/// carry on patching it.
///
/// What these pin is *which* failures mean that. A classifier refusal and a
/// runtime that declines both end in a refusal, and neither touched the running
/// process. Only a load that may have half-happened poisons the session.
///
/// The first version of this file reached TRANSFER and stopped, so two of its
/// tests passed while asserting nothing. Delivery is stubbed here so the load
/// path is actually reached.

private struct Harness {
    let coordinator: PatchCoordinator
    let runtime: FakeRuntime
    let subject: URL
    let root: URL
    let server: IPCServer

    var coordinatorServerHasSession: Bool { server.currentSession != nil }
}

/// A coordinator wired to a connected fake runtime, with compilation and
/// delivery stubbed so that what the runtime answers is what decides the
/// outcome.
private func harness(answering answer: @escaping @Sendable () -> LoadPatchResult,
                     processId: Int32 = 1,
                     sourceLocation: SourceLocation = #_sourceLocation) async throws -> Harness {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-uncertain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let subject = root.appendingPathComponent("S.swift")
    try #"struct S { func f() -> String { "old" } }"#
        .write(to: subject, atomically: true, encoding: .utf8)

    let image = root.appendingPathComponent("Patch.dylib")
    try Data().write(to: image)

    let server = try IPCServer()
    let port = try await server.start()

    let context = BuildContext(
        moduleName: "Fixture", swiftCompilerPath: "/usr/bin/true",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-splice.tests")

    let coordinator = PatchCoordinator(context: context, server: server,
                                       workDirectory: root.appendingPathComponent("patches"),
                                       deliver: { _ in image },
                                       // The tests have no built application,
                                       // so the module check would refuse
                                       // every edit before the stages they
                                       // are about.
                                       inventory: ModuleInventory(keys: ["Fixture": 1]))
    await coordinator.primeBaselines(from: [root])

    let runtime = FakeRuntime(port: port)
    // Asserted, not assumed. Left unchecked, a slow connect made `request`
    // throw before sending, which used to poison -- so the tests that expect a
    // poison passed for the wrong reason and the ones that expect none failed,
    // a flake reporting the opposite of the truth.
    #expect(await runtime.connect(), "the fake runtime never connected", sourceLocation: sourceLocation)
    try runtime.send(type: "hello", payload: Hello(
        token: server.token,
        buildIdentity: context.identity, moduleName: "Fixture",
        processId: processId, loadedGenerations: [], buildMatchesProcess: true))
    for _ in 0..<200 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.currentSession != nil, "the handshake never completed", sourceLocation: sourceLocation)
    runtime.responder = { envelope in
        guard envelope.type == "loadPatch" else { return nil }
        return ("loadResult", try! JSONEncoder().encode(answer()))
    }

    return Harness(coordinator: coordinator, runtime: runtime, subject: subject,
                   root: root, server: server)
}

private func edit(_ url: URL, to body: String) throws {
    try "struct S { func f() -> String { \(body) } }"
        .write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Poisoned

@Test func aFailedLoadPoisonsTheSession() async throws {
    let h = try await harness { .failed(stage: .register, message: "dlopen: symbol not found") }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the load failure to be reported")
        return
    }
    #expect(error.stage == .register)
    #expect(await h.coordinator.isUncertain, "a failure the runtime cannot vouch for leaves the process undescribable")
}

@Test func aPoisonedSessionRefusesLaterSavesWithoutExaminingThem() async throws {
    let h = try await harness { .failed(stage: .register, message: "dlopen: symbol not found") }
    try edit(h.subject, to: #""new""#)
    _ = await h.coordinator.handle(change: h.subject)
    #expect(await h.coordinator.isUncertain)

    try edit(h.subject, to: #""newer""#)
    guard case .sessionUncertain(let cause) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("a poisoned session kept patching")
        return
    }
    #expect(cause.reason.contains("dlopen"), "the refusal has to carry the original failure")
}

@Test func onlyADifferentProcessClearsIt() async throws {
    let h = try await harness { .failed(stage: .register, message: "dlopen: symbol not found") }
    try edit(h.subject, to: #""new""#)
    _ = await h.coordinator.handle(change: h.subject)
    #expect(await h.coordinator.isUncertain)

    // The same process reconnecting is not a restart.
    await h.coordinator.sessionDidConnect(processId: 1)
    #expect(await h.coordinator.isUncertain, "a reconnect from the same pid must not clear it")

    // A different pid is evidence of a new process.
    await h.coordinator.sessionDidConnect(processId: 2)
    #expect(await h.coordinator.isUncertain == false)

    try edit(h.subject, to: #""newest""#)
    if case .sessionUncertain = await h.coordinator.handle(change: h.subject) {
        Issue.record("still refusing after the app restarted")
    }
}

// MARK: - Not poisoned

@Test func aRuntimeThatDeclinesDoesNotPoison() async throws {
    // `.rejected` is the runtime saying it loaded nothing. The process is
    // exactly where it was, and demanding a relaunch would be wrong.
    let h = try await harness { .rejected(reason: "build identity does not match") }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected a refusal")
        return
    }
    #expect(error.recovery == .rebuild)
    #expect(await h.coordinator.isUncertain == false)
}

@Test func aClassifierRefusalDoesNotPoison() async throws {
    // Never reaches the process at all. Poisoning here would make an ordinary
    // "add a stored property" edit demand a relaunch.
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1) }

    try "struct S { var added = 1\n func f() -> String { \"old\" } }"
        .write(to: h.subject, atomically: true, encoding: .utf8)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the classifier to refuse a new stored property")
        return
    }
    #expect(error.stage == .classify)
    #expect(await h.coordinator.isUncertain == false)
}

@Test func aSuccessfulLoadLeavesTheSessionUsable() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1) }

    try edit(h.subject, to: #""new""#)
    guard case .applied = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the patch to be applied")
        return
    }
    #expect(await h.coordinator.isUncertain == false)
}

@Test func savingWithNoAppRunningDoesNotPoison() async throws {
    // The everyday case: the daemon is up, the app is not. The request never
    // leaves the daemon, so the app -- whenever it launches -- is exactly what
    // it was built as. Poisoning here told the developer their process was
    // undescribable when there was no process, and then hid every later
    // classify and compile error behind that message.
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1) }
    h.runtime.disconnect()
    for _ in 0..<200 where h.coordinatorServerHasSession { try await Task.sleep(for: .milliseconds(20)) }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected a refusal with nothing connected")
        return
    }
    #expect(error.stage == .load)
    #expect(await h.coordinator.isUncertain == false, "nothing was sent, so nothing is uncertain")
}

@Test func aRuntimeFailureThatTouchedNothingDoesNotPoison() async throws {
    // TRANSFER and LOAD are the stages the runtime uses when it knows nothing
    // took effect: a missing image was never opened, and dlopen unmaps an
    // image it could not finish binding.
    for stage in [Stage.transfer, Stage.load] {
        let h = try await harness { .failed(stage: stage, message: "no image at /tmp/x") }
        try edit(h.subject, to: #""new""#)
        guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
            Issue.record("expected a refusal for \(stage)")
            continue
        }
        #expect(error.stage == stage)
        #expect(await h.coordinator.isUncertain == false,
                "\(stage) means the runtime did not touch the process")
    }
}

@Test func aPatchBuiltForAnotherBinaryIsRefusedByTheRuntime() async throws {
    // Not a coordinator test: this is the runtime's own check, and until it
    // existed `.rejected` was unreachable, so the rule that some failures do
    // not poison had nothing real behind it. DESIGN.md section 6.3.
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1) }

    // The fake stands in for a runtime that compares identities, which the
    // real one now does before calling dlopen.
    h.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        let result: LoadPatchResult = request.buildIdentity == "something else"
            ? .loaded(generation: request.generation, durationMs: 1, registered: 1)
            : .rejected(reason: "the patch was built for a different binary")
        return ("loadResult", try! JSONEncoder().encode(result))
    }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the runtime's refusal to surface")
        return
    }
    #expect(error.recovery == .rebuild)
    #expect(await h.coordinator.isUncertain == false)
}

/// The check the identity comparison could never make.
///
/// Module, triple, SDK and compiler version are all equal for a running app and
/// for a newer build of the same sources, so the old comparison passed. The
/// linker's UUID is not, and only the process can say which one it is running.
@Test func aProcessRunningAnOlderBuildIsRefused() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1) }

    h.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        // What the real runtime does: look for one of these among its own
        // loaded images, and find none.
        let matched = request.buildUUIDs.contains("00000000-0000-0000-0000-00000000FFFF")
        let result: LoadPatchResult = matched
            ? .loaded(generation: request.generation, durationMs: 1, registered: 1)
            : .rejected(reason: "this process is not running the binary the patch was linked against")
        return ("loadResult", try! JSONEncoder().encode(result))
    }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the runtime's refusal to surface")
        return
    }
    #expect(error.reason.contains("not running the binary"))
    // Declined before anything was opened, so the session stays describable.
    #expect(error.recovery == .rebuild)
    #expect(await h.coordinator.isUncertain == false)
}

@Test func everyArchitectureSliceContributesAUUID() {
    // A Simulator binary is universal and each slice has a different UUID.
    // Reading only the first gave the x86_64 one while the process ran arm64,
    // which would have refused every patch ever sent.
    let uuids = BuildUUID.read(from: "/usr/bin/true")
    #expect(!uuids.isEmpty)
    #expect(Set(uuids).count == uuids.count, "slices must not report the same UUID")
    for uuid in uuids {
        #expect(UUID(uuidString: uuid) != nil, "not a UUID: \(uuid)")
    }
}

@Test func aBinaryThatCannotBeReadContributesNoUUID() {
    #expect(BuildUUID.read(from: "/nonexistent/binary").isEmpty)
}
