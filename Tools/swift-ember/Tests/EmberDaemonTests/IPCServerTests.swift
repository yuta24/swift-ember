import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

/// The daemon's half of the local channel.
///
/// These exist because a review found `request()` unable to time out at all,
/// and one hung request stops `watch` from processing anything ever again. That
/// failure was silent from the outside: no error, no log, just a daemon that
/// had quietly stopped working.

private func startedServer() async throws -> IPCServer {
    let server = try IPCServer()
    _ = try await server.start()
    return server
}

private func connectedRuntime(to server: IPCServer,
                              identity: String = "test-identity") async throws -> FakeRuntime {
    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()
    try runtime.send(type: "hello", payload: Hello(
        token: server.token,
        buildIdentity: identity, moduleName: "Test", processId: 1, loadedGenerations: [], buildMatchesProcess: true))

    // The handshake is what makes the server willing to send anything.
    for _ in 0..<100 {
        if server.currentSession != nil { return runtime }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the server never registered the hello")
    return runtime
}

@Test func aRequestGetsItsReply() async throws {
    let server = try await startedServer()
    defer { server.stop() }
    let runtime = try await connectedRuntime(to: server)

    runtime.responder = { envelope in
        guard envelope.type == "loadPatch" else { return nil }
        let result = LoadPatchResult.loaded(generation: 3, durationMs: 1.5, registered: 1, refreshed: nil)
        return ("loadResult", try! JSONEncoder().encode(result))
    }

    let request = LoadPatchRequest(generation: 3, path: "/tmp/x.dylib",
                                   buildIdentity: "test-identity", buildUUIDs: [], declarations: ["A.f()"])
    let result = try await server.request(type: "loadPatch", payload: request,
                                          expecting: LoadPatchResult.self)
    guard case .loaded(let generation, _, _, _) = result else {
        Issue.record("expected .loaded, got \(result)")
        return
    }
    #expect(generation == 3)
}

@Test func aSilentRuntimeTimesOutInsteadOfHanging() async throws {
    // The regression test. The original implementation raced the reply against
    // a timeout task inside a task group; when the timeout won, the group
    // cancelled the waiting child and then waited for it to finish, but
    // cancelling a task does not resume a checked continuation, so the call
    // never returned at all.
    let server = try await startedServer()
    defer { server.stop() }
    _ = try await connectedRuntime(to: server)   // connected, but never answers

    let start = Date()
    await #expect(throws: IPCServer.IPCError.self) {
        _ = try await server.request(type: "loadPatch",
                                     payload: LoadPatchRequest(generation: 1, path: "/tmp/x",
                                                               buildIdentity: "test-identity",
                                                               buildUUIDs: [],
                                                               declarations: []),
                                     expecting: LoadPatchResult.self,
                                     timeout: .milliseconds(300))
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 3, "took \(elapsed)s; the timeout did not fire")
}

@Test func losingTheAppFailsRequestsInFlight() async throws {
    // An app that crashes mid-patch -- which is exactly what a bad dlopen does
    // -- must not leave the daemon waiting on a socket that is gone.
    let server = try await startedServer()
    defer { server.stop() }
    let runtime = try await connectedRuntime(to: server)

    let pending = Task {
        try await server.request(
            type: "loadPatch",
            payload: LoadPatchRequest(generation: 1, path: "/tmp/x",
                                      buildIdentity: "test-identity", buildUUIDs: [], declarations: []),
            expecting: LoadPatchResult.self,
            timeout: .seconds(30))
    }

    try await Task.sleep(for: .milliseconds(200))
    let start = Date()
    runtime.disconnect()

    do {
        _ = try await pending.value
        Issue.record("the request resolved successfully after the app went away")
    } catch {
        #expect(Date().timeIntervalSince(start) < 5,
                "waited \(Date().timeIntervalSince(start))s; the disconnect did not settle the request")
    }
}

@Test func requestingWithNoAppConnectedFailsImmediately() async throws {
    let server = try await startedServer()
    defer { server.stop() }

    await #expect(throws: IPCServer.IPCError.self) {
        _ = try await server.request(type: "loadPatch",
                                     payload: LoadPatchRequest(generation: 1, path: "/tmp/x",
                                                               buildIdentity: "x", buildUUIDs: [], declarations: []),
                                     expecting: LoadPatchResult.self)
    }
}

@Test func severalMessagesInOneWriteAreAllRead() async throws {
    // Framing: nothing guarantees one read is one message.
    let server = try await startedServer()
    defer { server.stop() }

    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()

    var batch = Data()
    for index in 0..<3 {
        let hello = Hello(token: server.token, buildIdentity: "identity-\(index)", moduleName: "Test",
                          processId: Int32(index), loadedGenerations: [], buildMatchesProcess: true)
        batch.append(try Envelope(type: "hello", payload: hello).encodedLine())
    }
    runtime.sendRaw(batch)

    for _ in 0..<100 {
        if let session = server.currentSession, session.hello.processId == 2 { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the last of three batched messages never arrived; session was \(String(describing: server.currentSession?.hello.processId))")
}

@Test func aMessageSplitAcrossWritesIsReassembled() async throws {
    let server = try await startedServer()
    defer { server.stop() }

    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()

    let line = try Envelope(type: "hello", payload: Hello(
        token: server.token,
        buildIdentity: "split", moduleName: "Test", processId: 77, loadedGenerations: [], buildMatchesProcess: true)).encodedLine()
    let cut = line.count / 2
    runtime.sendRaw(line.prefix(cut))
    try await Task.sleep(for: .milliseconds(100))
    #expect(server.currentSession == nil, "half a message must not register")
    runtime.sendRaw(line.suffix(from: cut))

    for _ in 0..<100 {
        if server.currentSession?.hello.processId == 77 { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the reassembled message never arrived")
}

@Test func aVersionMismatchIsReportedRatherThanMisread() async throws {
    let server = try await startedServer()
    defer { server.stop() }

    let reported = Reported()
    server.onEvent = { reported.append($0) }

    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()

    var envelope = try Envelope(type: "hello", payload: Hello(
        token: server.token,
        buildIdentity: "x", moduleName: "Test", processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    envelope.protocolVersion = EmberProtocol.version + 1
    runtime.sendRaw(try envelope.encodedLine())

    for _ in 0..<100 {
        if reported.all.contains(where: { $0.contains("protocol version") }) {
            #expect(server.currentSession == nil, "a mismatched peer must not be treated as connected")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("no diagnostic for the version mismatch; saw \(reported.all)")
}

@Test func anUnreadablePayloadIsReportedRatherThanIgnored() async throws {
    let server = try await startedServer()
    defer { server.stop() }

    let reported = Reported()
    server.onEvent = { reported.append($0) }

    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()
    // A well-formed envelope whose payload is not a Hello.
    runtime.sendRaw(try Envelope(type: "hello", rawPayload: Data("{}".utf8)).encodedLine())

    for _ in 0..<100 {
        if reported.all.contains(where: { $0.contains("hello") }) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("a payload that could not be decoded was dropped silently; saw \(reported.all)")
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

// MARK: - Teardown races and framing

@Test func aRelaunchSurvivesTheOldSocketTearingDownLate() async throws {
    // NWConnection.cancel() is graceful, so a superseded socket can finish
    // tearing down after its replacement has already said hello. Untagged, that
    // late teardown wiped the fresh session, and the daemon then reported "no
    // app is connected" for every save afterwards -- permanently, since the
    // runtime only sends hello on connect.
    let server = try await startedServer()
    defer { server.stop() }

    let crashed = try await connectedRuntime(to: server, identity: "first")
    let relaunched = try await connectedRuntime(to: server, identity: "second")

    // The old app's socket goes away only now, after the new one is live.
    crashed.disconnect()
    try await Task.sleep(for: .milliseconds(300))

    #expect(server.currentSession?.hello.buildIdentity == "second",
            "the stale teardown wiped the current session")

    relaunched.responder = { envelope in
        ("loadResult", try! JSONEncoder().encode(LoadPatchResult.loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil)))
    }
    let result = try await server.request(
        type: "loadPatch",
        payload: LoadPatchRequest(generation: 1, path: "/tmp/x",
                                  buildIdentity: "second", buildUUIDs: [], declarations: []),
        expecting: LoadPatchResult.self,
        timeout: .seconds(3))
    guard case .loaded = result else {
        Issue.record("the relaunched app could not be reached: \(result)")
        return
    }
}

@Test func aBlankLineDoesNotStallTheMessagesBehindIt() async throws {
    // The drain loop treated an empty line as "nothing complete yet" and
    // returned, abandoning every message already buffered behind it.
    let server = try await startedServer()
    defer { server.stop() }

    let runtime = FakeRuntime(port: server.port)
    await runtime.connect()

    var payload = Data("\n".utf8)
    payload.append(try Envelope(type: "hello", payload: Hello(
        token: server.token,
        buildIdentity: "after-blank", moduleName: "Test",
        processId: 99, loadedGenerations: [], buildMatchesProcess: true)).encodedLine())
    runtime.sendRaw(payload)

    for _ in 0..<100 {
        if server.currentSession?.hello.processId == 99 { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the message behind the blank line never arrived")
}

@Test func startingAnAlreadyStoppedServerFailsRatherThanHangs() async throws {
    // A cancelled listener never reports anything to a handler installed after
    // the fact, so waiting on one is waiting forever. This is the shape that
    // hung a full test run: the same code passed in isolation and deadlocked
    // when scheduling went the other way.
    let server = try IPCServer()
    server.stop()
    await #expect(throws: IPCServer.StartupError.self) {
        _ = try await server.start()
    }
}

@Test func stoppingDuringStartupSettlesTheCaller() async throws {
    let server = try IPCServer()
    let starting = Task { try await server.start() }
    server.stop()

    // Either outcome is correct. What is not correct is never returning.
    do { _ = try await starting.value } catch { }
}

/// The token was generated, written into the session file, and read by nobody
/// for the life of the project, while a comment claimed it stopped another
/// local process posing as the app.
///
/// The harm is not mainly secrecy. The daemon keeps one session at a time, so a
/// second connection displaces the app -- after which every patch is sent
/// somewhere else and answered, and the tool reports reloads that never reached
/// the process.
@Test func aConnectionWithoutTheSessionTokenNeverBecomesTheSession() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let impostor = FakeRuntime(port: port)
    #expect(await impostor.connect())
    try impostor.send(type: "hello", payload: Hello(
        token: "not-the-session-token", buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))

    // Give the daemon a moment to read it and refuse.
    try await Task.sleep(for: .milliseconds(300))
    #expect(server.currentSession == nil)

    // And with nothing connected, a request never leaves the daemon -- the one
    // failure that does not poison a session.
    do {
        _ = try await server.request(type: "loadPatch",
                                     payload: LoadPatchRequest(generation: 1, path: "/tmp/x",
                                                               buildIdentity: "id", buildUUIDs: [],
                                                               declarations: []),
                                     expecting: LoadPatchResult.self)
        Issue.record("expected notConnected")
    } catch {
        #expect("\(error)" == "\(IPCServer.IPCError.notConnected)")
    }
}

// MARK: - What an unauthenticated connection may and may not do

/// Accepting a socket used to be the same thing as becoming the session: the
/// incoming connection cleared `session` and failed every request in flight
/// before a single byte was read. A port scan, a stray `nc`, or a second
/// `watch` therefore ended the developer's session -- measured against the real
/// sample app as four consecutive saves failing with "no app is connected", and
/// no `disconnected` line to explain why.
@Test func aSilentConnectionDoesNotEvictTheApp() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())
    try app.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    try await Task.sleep(for: .milliseconds(300))
    #expect(server.currentSession != nil)

    let intruder = FakeRuntime(port: port)
    #expect(await intruder.connect())
    try await Task.sleep(for: .milliseconds(400))

    #expect(server.currentSession != nil, "a connection that said nothing took the session")
    #expect(server.currentSession?.hello.processId == 1)
}

/// The same, for a peer that speaks but cannot prove it is the app.
@Test func aBadTokenDoesNotEvictTheApp() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())
    try app.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    try await Task.sleep(for: .milliseconds(300))

    let impostor = FakeRuntime(port: port)
    #expect(await impostor.connect())
    try impostor.send(type: "hello", payload: Hello(
        token: "wrong", buildIdentity: "id", moduleName: "M",
        processId: 2, loadedGenerations: [], buildMatchesProcess: true))
    try await Task.sleep(for: .milliseconds(400))

    #expect(server.currentSession?.hello.processId == 1, "an impostor took the session")
}

/// A peer that never completes a message used to grow the daemon's buffer
/// without bound *and* re-scan all of it on every read -- 32 MiB cost 61 seconds
/// at 100% of a core, on the same serial queue that fires reply handlers and
/// request timeouts. A half-millisecond save became a 32-second stall and then a
/// poisoned session.
@Test func aFloodOfHeaderlessBytesDoesNotStallTheDaemon() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())
    app.responder = { envelope in
        guard envelope.type == "loadPatch" else { return nil }
        let result = LoadPatchResult.loaded(generation: 1, durationMs: 1, registered: 1, refreshed: nil)
        return ("loadResult", try! JSONEncoder().encode(result))
    }
    try app.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    try await Task.sleep(for: .milliseconds(300))

    let flood = FakeRuntime(port: port)
    #expect(await flood.connect())
    let chunk = Data(repeating: 0x41, count: 1 << 20)
    for _ in 0..<8 { flood.sendRaw(chunk) }

    let start = DispatchTime.now().uptimeNanoseconds
    let request = LoadPatchRequest(generation: 1, path: "/tmp/x", buildIdentity: "id",
                                   buildUUIDs: [], declarations: ["A.f()"])
    _ = try await server.request(type: "loadPatch", payload: request,
                                 expecting: LoadPatchResult.self, timeout: .seconds(20))
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    #expect(ms < 2000, "the flood stalled the daemon for \(Int(ms)) ms")
    #expect(server.currentSession != nil, "the flood took the session")
}

/// A reply the daemon cannot read is settled at once. Dropping it left the
/// request to burn its whole timeout and then fail as "the app did not answer",
/// which ends the session -- for a runtime that answered immediately and whose
/// answer said exactly what was wrong.
@Test func aReplyAtTheWrongProtocolVersionFailsImmediately() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())
    try app.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    try await Task.sleep(for: .milliseconds(300))

    // Answers with a stale protocol version, by hand: FakeRuntime's own `send`
    // always stamps the current one.
    app.responder = { [weak app] envelope in
        guard envelope.type == "loadPatch" else { return nil }
        var line = Data(#"{"protocolVersion":1,"type":"loadResult","requestId":"#.utf8)
        line.append(Data("\"\(envelope.requestId)\",\"payload\":\"e30=\"}\n".utf8))
        app?.sendRaw(line)
        return nil
    }

    let request = LoadPatchRequest(generation: 1, path: "/tmp/x", buildIdentity: "id",
                                   buildUUIDs: [], declarations: [])
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        _ = try await server.request(type: "loadPatch", payload: request,
                                     expecting: LoadPatchResult.self, timeout: .seconds(10))
        Issue.record("expected the request to fail")
    } catch {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        #expect(ms < 1000, "waited \(Int(ms)) ms for an answer it could never read")
        #expect("\(error)".contains("upgrade one side"), "was: \(error)")
    }
}

/// A runtime built before the protocol moved is the ordinary case after this
/// tool is updated and the application is not rebuilt, and it must say so.
///
/// The hello is rejected, so no session is ever created. Every later request
/// then failed as "no app is connected" with an action of "restart the app" --
/// a loop with no exit, since restarting relaunches the same old runtime. What
/// is needed is a build, and now that is what it says.
@Test func aRuntimeAtAnOlderProtocolVersionSaysSoOnEveryRequest() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())

    // By hand, because FakeRuntime always stamps the current version.
    let hello = try JSONEncoder().encode(Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    var line = Data(#"{"protocolVersion":4,"type":"hello","requestId":"x","payload":"#.utf8)
    line.append(Data("\"\(hello.base64EncodedString())\"}\n".utf8))
    app.sendRaw(line)
    try await Task.sleep(for: .milliseconds(300))

    #expect(server.currentSession == nil, "a runtime this daemon cannot read must not hold the session")

    let request = LoadPatchRequest(generation: 1, path: "/tmp/x", buildIdentity: "id",
                                   buildUUIDs: [], declarations: [])
    do {
        _ = try await server.request(type: "loadPatch", payload: request,
                                     expecting: LoadPatchResult.self, timeout: .seconds(2))
        Issue.record("expected the request to fail")
    } catch let error as IPCServer.IPCError {
        guard case .versionMismatch(let version) = error else {
            Issue.record("expected .versionMismatch, got \(error)")
            return
        }
        #expect(version == 4)
        #expect("\(error)".contains("protocol 4"))
    }

    // And it stops being the answer once a runtime this daemon can read shows
    // up. The flag outlived the problem: after a rebuild fixed it, quitting
    // the app reported "rebuild it" again.
    let rebuilt = FakeRuntime(port: port)
    #expect(await rebuilt.connect())
    try rebuilt.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 2, loadedGenerations: [], buildMatchesProcess: true))
    for _ in 0..<200 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.currentSession != nil, "the rebuilt runtime should hold the session")

    rebuilt.disconnect()
    for _ in 0..<200 where server.currentSession != nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    do {
        _ = try await server.request(type: "loadPatch", payload: request,
                                     expecting: LoadPatchResult.self, timeout: .seconds(2))
        Issue.record("expected the request to fail")
    } catch let error as IPCServer.IPCError {
        guard case .notConnected = error else {
            Issue.record("expected .notConnected after the mismatch was resolved, got \(error)")
            return
        }
    }
}

/// A version this daemon cannot read explains why there is *no* session. It
/// must not be allowed to describe one that exists.
///
/// The version guard runs before the type switch and before the token check,
/// so every envelope from every unauthenticated socket reached it. One stray
/// message at an old version, from anything at all on the loopback port, and a
/// healthy session was reported to the developer as needing a rebuild --- which
/// is the invariant `accept()` was rewritten to hold: nothing decides what the
/// daemon says about the session until it has proved it came from the app.
@Test func aStrayMessageAtAnOldVersionCannotSpeakForALiveSession() async throws {
    let server = try IPCServer()
    let port = try await server.start()
    defer { server.stop() }

    let app = FakeRuntime(port: port)
    #expect(await app.connect())
    try app.send(type: "hello", payload: Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 1, loadedGenerations: [], buildMatchesProcess: true))
    for _ in 0..<200 where server.currentSession == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(server.currentSession != nil)

    // Something else on the loopback port, with no token, at an old version.
    let stray = FakeRuntime(port: port)
    #expect(await stray.connect())
    stray.sendRaw(Data(#"{"protocolVersion":4,"type":"loadResult","requestId":"x","payload":"e30="}"#.utf8) + Data("\n".utf8))
    // And an old-version hello too, which is the shape that does get recorded
    // when there is no session to protect.
    let hello = try JSONEncoder().encode(Hello(
        token: server.token, buildIdentity: "id", moduleName: "M",
        processId: 9, loadedGenerations: [], buildMatchesProcess: true))
    var line = Data(#"{"protocolVersion":4,"type":"hello","requestId":"y","payload":"#.utf8)
    line.append(Data("\"\(hello.base64EncodedString())\"}\n".utf8))
    stray.sendRaw(line)
    try await Task.sleep(for: .milliseconds(300))

    #expect(server.currentSession != nil, "the stray peer must not take the session")

    // The app quits normally. The answer is that nothing is connected, not
    // that the app needs rebuilding.
    app.disconnect()
    for _ in 0..<200 where server.currentSession != nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    let request = LoadPatchRequest(generation: 1, path: "/tmp/x", buildIdentity: "id",
                                   buildUUIDs: [], declarations: [])
    do {
        _ = try await server.request(type: "loadPatch", payload: request,
                                     expecting: LoadPatchResult.self, timeout: .seconds(2))
        Issue.record("expected the request to fail")
    } catch let error as IPCServer.IPCError {
        guard case .notConnected = error else {
            Issue.record("a stray socket decided what the daemon says: \(error)")
            return
        }
    }
}
