#if SPLICE_ENABLED

import Foundation
import Network

/// Dials the daemon and answers its requests.
///
/// The runtime is the client so that relaunching the app reconnects on its own,
/// which DESIGN.md section 11.1 asks for. Where to dial comes from a session
/// file the daemon writes into this app's own container: a path the app can
/// always read, unlike a well-known location on the host.
final class SpliceClient: @unchecked Sendable {
    private struct Session: Codable {
        let port: Int
        let token: String
        let buildIdentity: String
        let buildUUIDs: [String]
    }

    private let state: Splice.StateBox
    /// What the session file said this process was built as. Compared against
    /// every incoming patch.
    private var expectedBuildIdentity = ""
    /// The link target's UUIDs, as the daemon read them off disk. Unlike the
    /// identity above, this is checked against the process itself.
    private var expectedBuildUUIDs: [String] = []
    private let queue = DispatchQueue(label: "dev.swift-splice.runtime")
    private var connection: NWConnection?
    private var buffer = Data()
    private var redialScheduled = false
    private let lock = NSLock()

    init(state: Splice.StateBox) { self.state = state }

    private var sessionURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("splice-session.json")
    }

    func start() { queue.async { self.dial() } }

    /// Every path that loses the connection funnels through `retry()`, so
    /// there is exactly one place that decides when to try again. An earlier
    /// version relied on NWConnection recovering from `.waiting` by itself and
    /// an app whose daemon had stopped never reconnected.
    private func retry() {
        let alreadyScheduled = lock.withLock { () -> Bool in
            if redialScheduled { return true }
            redialScheduled = true
            return false
        }
        guard !alreadyScheduled else { return }
        state.setConnected(false)
        queue.asyncAfter(deadline: .now() + 1) { self.dial() }
    }

    private func dial() {
        lock.withLock { redialScheduled = false }

        // Drop whatever came before. A half-closed socket left behind keeps a
        // descriptor and confuses anyone reading `lsof`.
        //
        // `self.` is not decoration. Written with an implicit self, this line
        // crashes the type checker in Swift 6.3.2 and earlier -- signal 5 while
        // type-checking `dial()` -- which is every released toolchain at the
        // time of writing. Explicit self compiles everywhere.
        lock.withLock { self.connection }?.cancel()
        lock.withLock { self.connection = nil; self.buffer = Data() }

        // `UInt16(_:)` rather than `UInt16(exactly:)` was a trap on a value read
        // off disk: a session file saying `"port": 70000` killed the app from a
        // background queue on the retry timer, with an assertion failure and no
        // other explanation. Every other malformed input on this path -- missing
        // file, corrupt JSON, wrong shape -- already degrades to a retry.
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              let number = UInt16(exactly: session.port),
              let port = NWEndpoint.Port(rawValue: number)
        else {
            // No daemon has announced itself yet. Keep looking; the developer
            // may start `swift-splice watch` after the app.
            retry()
            return
        }

        expectedBuildIdentity = session.buildIdentity
        expectedBuildUUIDs = session.buildUUIDs

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        lock.withLock { self.connection = connection }

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.state.setConnected(true)
                self.send(type: "hello", payload: Hello(
                    token: session.token,
                    buildIdentity: session.buildIdentity,
                    moduleName: Bundle.main.bundleIdentifier ?? "unknown",
                    processId: ProcessInfo.processInfo.processIdentifier,
                    loadedGenerations: self.state.generations,
                    buildMatchesProcess: LoadedImages.running(oneOf: session.buildUUIDs)),
                    requestId: UUID().uuidString)
                self.receive(on: connection)
            case .waiting:
                // The daemon is not listening. Network.framework would hold
                // this connection open and retry on its own schedule; taking
                // it down and dialling again keeps the timing predictable.
                connection.cancel()
            case .failed, .cancelled:
                self.retry()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.buffer.append(data) }
                self.drain()
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func drain() {
        while true {
            let line: Data? = lock.withLock {
                guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<index])
                buffer = buffer[buffer.index(after: index)...]
                return line
            }
            // A blank line is not the end of the buffer: skip it and keep
            // draining. Returning here left every message queued behind it
            // waiting for the next read, which between saves may never come --
            // measured as a reply that arrived only when six seconds of
            // unrelated traffic dislodged it, long after the daemon had timed
            // out and ended the session. The daemon's own drain loop was fixed
            // for this and carries the same comment; this one was missed.
            guard let line else { return }
            if line.isEmpty { continue }
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            state.note("could not read a message from the daemon")
            return
        }
        guard envelope.protocolVersion == ProtocolVersion else {
            // Answered, not dropped. The rule two branches down -- never leave a
            // request unanswered -- applies here too, and this was the one case
            // that broke it: the daemon waited out its full ten-second timeout
            // and then reported "the app did not answer" for a runtime that had
            // understood the problem immediately and could say so.
            state.note("daemon speaks protocol \(envelope.protocolVersion), this runtime speaks \(ProtocolVersion)")
            send(type: "loadResult",
                 payload: LoadPatchResult.failed(
                    stage: "LOAD",
                    message: "the runtime speaks protocol \(ProtocolVersion) and the daemon speaks \(envelope.protocolVersion); upgrade one side"),
                 requestId: envelope.requestId)
            return
        }

        switch envelope.type {
        case "loadPatch":
            guard let request = try? envelope.decode(LoadPatchRequest.self) else {
                // Never leave a request unanswered. The daemon is waiting on
                // this requestId, and silence used to wedge it until its
                // timeout -- or, before that timeout worked, forever.
                state.note("could not read a loadPatch request; the two sides' protocol types have drifted")
                send(type: "loadResult",
                     payload: LoadPatchResult.failed(stage: "LOAD",
                                                     message: "the runtime could not decode the request"),
                     requestId: envelope.requestId)
                return
            }
            let result = apply(request)
            send(type: "loadResult", payload: result, requestId: envelope.requestId)
        default:
            state.note("ignored \(envelope.type)")
        }
    }

    private func apply(_ request: LoadPatchRequest) -> LoadPatchResult {
        // DESIGN.md section 6.3: a patch built against a different binary must
        // not be applied. The daemon has always sent its build identity and
        // nothing checked it, which also left `.rejected` -- the one answer
        // meaning "declined without touching anything" -- unreachable, so the
        // rule that some failures do not poison the session was untested
        // against anything real.
        if request.buildIdentity != expectedBuildIdentity {
            state.note("refused g\(request.generation): built for a different binary")
            return .rejected(reason: """
                the patch was built for \(request.buildIdentity) and this process is \
                \(expectedBuildIdentity); rebuild and relaunch
                """)
        }

        // The check above compares two strings the daemon wrote. This one asks
        // the process. Module, triple, SDK and compiler version are all equal
        // for a running app and for a newer build of the same sources, which is
        // exactly the pair that must not be confused -- the daemon links
        // patches against what is on disk now, and this process is running what
        // was on disk when it launched.
        if !LoadedImages.running(oneOf: request.buildUUIDs) {
            state.note("refused g\(request.generation): this process is a different build")
            return .rejected(reason: """
                this process is not running the binary the patch was linked against. \
                It was built again after the app launched; relaunch it.
                """)
        }

        switch Splice.load(generation: request.generation, path: request.path) {
        case .loaded(let generation, let durationMs, let registered):
            let names = request.declarations.joined(separator: ", ")
            state.note("g\(generation): \(names.isEmpty ? "loaded" : names)")
            return .loaded(generation: generation, durationMs: durationMs, registered: registered,
                           refreshed: refreshUIKit())
        case .failed(let stage, let message):
            state.note("g\(request.generation) failed at \(stage): \(message)")
            return .failed(stage: stage, message: message)
        }
    }

    /// Makes the loaded generation visible, and says what that took.
    ///
    /// UIKit has to be told to call anything again; see UIKitRefresh. The wait
    /// is bounded rather than a plain `DispatchQueue.main.sync` because an
    /// application whose main thread is blocked would otherwise hold this
    /// connection until the daemon's ten-second timeout and poison the session
    /// -- over a reload that had already succeeded.
    private func refreshUIKit() -> String? {
        // The same condition UIKitRefresh is declared under, and it has to
        // stay the same: `canImport(UIKit)` alone is true on watchOS, where
        // that file does not exist, and the mismatch is a build failure rather
        // than a missing feature.
        #if canImport(UIKit) && !os(watchOS)
        let options = state.refresh
        guard !options.isEmpty else { return nil }

        final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let holder = Holder()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { holder.value = UIKitRefresh.perform(options) }
            finished.signal()
        }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            // Not "not refreshed". The block stays queued and the screen does
            // update once the main thread is free -- measured -- so saying it
            // did not happen would be the reverse of the lie this tool is
            // built to avoid. What is true is that nobody waited to see.
            return "still running; the main thread did not answer within 2 s"
        }
        return holder.value
        #else
        return nil
        #endif
    }

    private func send<P: Encodable>(type: String, payload: P, requestId: String) {
        guard let connection = lock.withLock({ self.connection }),
              let body = try? JSONEncoder().encode(payload) else { return }
        let envelope = Envelope(protocolVersion: ProtocolVersion, type: type,
                                requestId: requestId, payload: body)
        guard var data = try? JSONEncoder().encode(envelope) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

// The wire types are duplicated rather than shared with the host package: the
// runtime has to build for the simulator inside the application's own module,
// and a SwiftPM dependency would drag the host's world along with it. The
// protocol version guards the duplication -- if these drift, the handshake
// says so instead of misreading a payload.

let ProtocolVersion = 5

struct Envelope: Codable {
    var protocolVersion: Int
    var type: String
    var requestId: String
    var payload: Data

    func decode<P: Decodable>(_ type: P.Type) throws -> P {
        try JSONDecoder().decode(P.self, from: payload)
    }
}

struct Hello: Codable {
    var token: String
    var buildIdentity: String
    var moduleName: String
    var processId: Int32
    var loadedGenerations: [UInt64]
    var buildMatchesProcess: Bool
}

struct LoadPatchRequest: Codable {
    var generation: UInt64
    var path: String
    var buildIdentity: String
    var buildUUIDs: [String]
    var declarations: [String]
}

enum LoadPatchResult: Codable {
    case loaded(generation: UInt64, durationMs: Double, registered: Int?, refreshed: String?)
    case rejected(reason: String)
    case failed(stage: String, message: String)
}

#endif
