import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

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
                     source: String = #"struct S { func f() -> String { "old" } }"#,
                     sourceLocation: SourceLocation = #_sourceLocation) async throws -> Harness {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ember-uncertain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let subject = root.appendingPathComponent("S.swift")
    try source.write(to: subject, atomically: true, encoding: .utf8)

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
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.tests")

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
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }

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
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }

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
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }
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
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }

    // The fake stands in for a runtime that compares identities, which the
    // real one now does before calling dlopen.
    h.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        let result: LoadPatchResult = request.buildIdentity == "something else"
            ? .loaded(generation: request.generation, durationMs: 1, registered: 1, refreshed: nil)
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
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }

    h.runtime.responder = { envelope in
        guard envelope.type == "loadPatch",
              let request = try? envelope.decode(LoadPatchRequest.self) else { return nil }
        // What the real runtime does: look for one of these among its own
        // loaded images, and find none.
        let matched = request.buildUUIDs.contains("00000000-0000-0000-0000-00000000FFFF")
        let result: LoadPatchResult = matched
            ? .loaded(generation: request.generation, durationMs: 1, registered: 1, refreshed: nil)
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

/// FR-13's case: the image registered fewer replacements than the patch
/// generated, so the patch did less than it said and the process can no longer
/// be described.
@Test func registeringFewerReplacementsThanGeneratedEndsTheSession() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 0, refreshed: nil) }
    try edit(h.subject, to: #""new""#)
    guard case .rejected(let error) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected a REGISTER failure")
        return
    }
    #expect(error.stage == .register)
    #expect(error.recovery == .restart)
    #expect(await h.coordinator.isUncertain)
}

/// More than generated is a different thing. A patch cannot register a
/// replacement it does not contain, so a count above the expected one says the
/// reader misread the image -- and ending the session every time a toolchain
/// moves a field is not a trade worth making. The reload stands, unverified.
@Test func registeringMoreThanGeneratedIsUnverifiedRatherThanFatal() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 99, refreshed: nil) }
    try edit(h.subject, to: #""new""#)
    guard case .applied(_, _, _, let verified, _, _, _, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(verified == false)
    #expect(await h.coordinator.isUncertain == false)
}

/// A count the runtime could not read at all. The check that cannot run must
/// not become a refusal.
@Test func anUnreadableCountIsReportedRatherThanRefused() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: nil, refreshed: nil) }
    try edit(h.subject, to: #""new""#)
    guard case .applied(_, _, _, let verified, _, _, _, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(verified == false)
    #expect(await h.coordinator.isUncertain == false)
}

// MARK: - One-shot lifecycle

/// A method that has already run is named, so the developer is not left
/// staring at a screen that did not change.
///
/// Name-based, and the fixture says so: a plain Swift class, no `NSObject`,
/// no `override`, nothing UIKit. That is the rule --- anything called
/// `viewDidLoad` on a type earns the note --- and it is what makes the two
/// exclusions below worth testing.
///
/// The reload itself stands: the body really is replaced, and every instance
/// created from now on runs it. What must not happen is silence, which is the
/// same standard `some View` is refused under.
@Test func aReplacedViewDidLoadIsCalledOutAsAlreadyRun() async throws {
    let before = "class Screen { func viewDidLoad() { print(\"old\") } }"
    let h = try await harness(answering: { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) },
                              source: before)
    try before.replacingOccurrences(of: "\"old\"", with: "\"new\"")
        .write(to: h.subject, atomically: true, encoding: .utf8)

    guard case .applied(_, _, _, _, _, _, let oneShot, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(oneShot == [OneShotNote(name: "Screen.viewDidLoad()", scope: .instance)])
}

/// And an ordinary method is not, so the note means something when it appears.
@Test func anOrdinaryMethodIsNotCalledOutAsAlreadyRun() async throws {
    let h = try await harness { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) }
    try edit(h.subject, to: #""new""#)
    guard case .applied(_, _, _, _, _, _, let oneShot, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(oneShot.isEmpty)
}

/// A *property* called `viewDidLoad` must not be named.
///
/// It is re-read on every access, so "nothing calls it again" would be the
/// reverse of the truth --- the same kind of lie the note exists to prevent,
/// pointed the other way.
///
/// What keeps it out is the spelling: every entry in `oneShotLifecycleTargets`
/// carries its parentheses and a property's replacement target is the bare
/// name. That is a quiet invariant, so `everyOneShotTargetIsSpelledAsAFunction`
/// pins it directly and this case pins the behaviour it produces.
@Test func aPropertyNamedLikeALifecycleMethodIsNotCalledOut() async throws {
    let before = "class Screen { var viewDidLoad: Int { 1 } }"
    let h = try await harness(answering: { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) },
                              source: before)
    try before.replacingOccurrences(of: "{ 1 }", with: "{ 2 }")
        .write(to: h.subject, atomically: true, encoding: .utf8)

    guard case .applied(_, let declarations, _, _, _, _, let oneShot, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(declarations.count == 1, "the property should still be reloaded")
    #expect(oneShot.isEmpty)
}

/// Nor a top-level function: the advice names a type, and there is none.
@Test func aTopLevelFunctionNamedLikeALifecycleMethodIsNotCalledOut() async throws {
    let before = #"func viewDidLoad() -> String { "old" }"#
    let h = try await harness(answering: { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) },
                              source: before)
    try before.replacingOccurrences(of: #""old""#, with: #""new""#)
        .write(to: h.subject, atomically: true, encoding: .utf8)

    guard case .applied(_, let declarations, _, _, _, _, let oneShot, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(declarations.count == 1)
    #expect(oneShot.isEmpty)
}

/// The strongest one-shot there is: an application is launched once per
/// process, so this one provably never runs again. Matched by its argument
/// labels, since the name alone is just `application`.
@Test func anAppDelegateLaunchMethodIsCalledOutAsAlreadyRun() async throws {
    let before = """
        class Delegate {
            func application(_ app: Int, didFinishLaunchingWithOptions options: Int) -> Bool { true }
        }
        """
    let h = try await harness(answering: { .loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil) },
                              source: before)
    try before.replacingOccurrences(of: "{ true }", with: "{ false }")
        .write(to: h.subject, atomically: true, encoding: .utf8)

    guard case .applied(_, _, _, _, _, _, let oneShot, _) = await h.coordinator.handle(change: h.subject) else {
        Issue.record("expected the reload to stand")
        return
    }
    #expect(oneShot == [OneShotNote(
        name: "Delegate.application(_:didFinishLaunchingWithOptions:) (Int,Int)",
        // Not `.instance`: there is one delegate per process, and a relaunched
        // process starts from the built binary with no patch loaded, so the
        // advice that tells you to make another one would not work.
        scope: .process)])
}

/// The invariant that keeps properties out of the one-shot note.
///
/// A property's replacement target is the bare name, so an entry spelled with
/// its parentheses cannot match one. Nothing in `oneShotLifecycleMethods` says
/// that --- it falls out of how the entries are written --- so a later entry
/// added without parentheses would silently reopen the case the test above
/// exists for, and every test would still pass.
@Test func everyOneShotTargetIsSpelledAsAFunction() {
    for target in PatchCoordinator.oneShotLifecycleTargets.keys {
        #expect(target.hasSuffix(")") && target.contains("("),
                "\(target) would match a property of the same name")
    }
}
