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
}

/// A coordinator wired to a connected fake runtime, with compilation and
/// delivery stubbed so that what the runtime answers is what decides the
/// outcome.
private func harness(answering answer: @escaping @Sendable () -> LoadPatchResult) async throws -> Harness {
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
                                       deliver: { _ in image })
    await coordinator.primeBaselines(from: [root])

    let runtime = FakeRuntime(port: port)
    await runtime.connect()
    try runtime.send(type: "hello", payload: Hello(
        buildIdentity: context.identity, moduleName: "Fixture",
        processId: 1, loadedGenerations: []))
    for _ in 0..<100 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    runtime.responder = { envelope in
        guard envelope.type == "loadPatch" else { return nil }
        return ("loadResult", try! JSONEncoder().encode(answer()))
    }

    return Harness(coordinator: coordinator, runtime: runtime, subject: subject, root: root)
}

private func edit(_ url: URL, to body: String) throws {
    try "struct S { func f() -> String { \(body) } }"
        .write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Poisoned

@Test func aFailedLoadPoisonsTheSession() async throws {
    let h = try await harness { .failed(stage: .load, message: "dlopen: symbol not found") }

    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the load failure to be reported")
        return
    }
    #expect(error.stage == .load)
    #expect(await h.coordinator.isUncertain, "a failed load leaves the process undescribable")
}

@Test func aPoisonedSessionRefusesLaterSavesWithoutExaminingThem() async throws {
    let h = try await harness { .failed(stage: .load, message: "dlopen: symbol not found") }
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

@Test func aFreshProcessClearsIt() async throws {
    let h = try await harness { .failed(stage: .load, message: "dlopen: symbol not found") }
    try edit(h.subject, to: #""new""#)
    _ = await h.coordinator.handle(change: h.subject)
    #expect(await h.coordinator.isUncertain)

    // The runtime dials, so a connection is a new process -- the only state
    // this daemon can vouch for without having watched it become that way.
    await h.coordinator.sessionDidRestart()
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
    let h = try await harness { .loaded(generation: 1, durationMs: 1) }

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
    let h = try await harness { .loaded(generation: 1, durationMs: 1) }

    try edit(h.subject, to: #""new""#)
    guard case .applied = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the patch to be applied")
        return
    }
    #expect(await h.coordinator.isUncertain == false)
}
