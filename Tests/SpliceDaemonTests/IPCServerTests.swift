import Foundation
import Testing
import SpliceCore
@testable import SpliceDaemon

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
        buildIdentity: identity, moduleName: "Test", processId: 1, loadedGenerations: []))

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
        let result = LoadPatchResult.loaded(generation: 3, durationMs: 1.5)
        return ("loadResult", try! JSONEncoder().encode(result))
    }

    let request = LoadPatchRequest(generation: 3, path: "/tmp/x.dylib",
                                   buildIdentity: "test-identity", declarations: ["A.f()"])
    let result = try await server.request(type: "loadPatch", payload: request,
                                          expecting: LoadPatchResult.self)
    guard case .loaded(let generation, _) = result else {
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
                                      buildIdentity: "test-identity", declarations: []),
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
                                                               buildIdentity: "x", declarations: []),
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
        let hello = Hello(buildIdentity: "identity-\(index)", moduleName: "Test",
                          processId: Int32(index), loadedGenerations: [])
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
        buildIdentity: "split", moduleName: "Test", processId: 77, loadedGenerations: [])).encodedLine()
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
        buildIdentity: "x", moduleName: "Test", processId: 1, loadedGenerations: []))
    envelope.protocolVersion = SpliceProtocol.version + 1
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
