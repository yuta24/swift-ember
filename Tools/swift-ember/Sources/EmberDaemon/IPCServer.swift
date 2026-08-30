import Foundation
import Network
import os
import EmberCore

/// The daemon end of the local development channel (DESIGN.md section 11).
///
/// The daemon listens and the runtime dials in, which is what makes
/// reconnection after an app relaunch fall out for free: a new process simply
/// connects again.
///
/// Loopback and a per-session token (PRD.md section 12). The token was
/// generated and written into the session file from the beginning and read by
/// nobody, so the comment that used to sit here described a check that did not
/// exist. It does now: a connection that does not present it never becomes the
/// session.
public final class IPCServer: @unchecked Sendable {
    public struct Session: Sendable {
        public let hello: Hello
        public let connectedAt: Date
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.swift-ember.ipc")
    private let lock = NSLock()
    private var stopped = false
    /// Set while `start()` is waiting, so `stop()` can settle it.
    private var startupFinish: (@Sendable (Result<UInt16, Error>) -> Void)?
    /// Every accepted socket, authenticated or not, keyed by the id given at
    /// accept. `NWConnection.cancel()` is graceful, so a superseded socket can
    /// finish tearing down long after its replacement is live; the id is how a
    /// late teardown knows which peer it belongs to.
    private var peers: [UInt64: Peer] = [:]
    private var connectionGeneration: UInt64 = 0
    /// The one peer that has presented the token. Only this one is sent to.
    private var sessionPeer: UInt64?
    /// A peer that announced a protocol version this daemon cannot read, if
    /// one did and there was no session for it to be measured against. Kept so
    /// that requests made afterwards say why there is no session, and keyed by
    /// peer so it goes away with the peer that caused it.
    private var mismatched: (peer: UInt64, version: Int)?
    private var session: Session?
    private var pending: [String: CheckedContinuation<Envelope, Error>] = [:]

    /// Valid once `start()` has returned.
    public var port: UInt16 { lock.withLock { _port } }
    private var _port: UInt16 = 0
    public let token: String

    public var onEvent: (@Sendable (String) -> Void)?
    public var onConnect: (@Sendable (Hello) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    public var currentSession: Session? { lock.withLock { session } }

    /// Pass a port to pin one; omit it to take whatever the system offers.
    ///
    /// Ephemeral is the default because the runtime learns where to dial from
    /// the session file, so nothing needs a well-known number, and two projects
    /// can then run `watch` at the same time without fighting over one.
    public init(port: UInt16? = nil) throws {
        self.token = UUID().uuidString
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let host = NWEndpoint.Host("127.0.0.1")
        if let port, let resolved = NWEndpoint.Port(rawValue: port) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: resolved)
        } else {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: .any)
        }
        self.listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port actually bound.
    public func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let listener = self.listener
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // The listener can report .ready and later .failed; resume once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { [weak self] result in
                let alreadyResumed = resumed.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                guard !alreadyResumed else { return }
                self?.lock.withLock { self?.startupFinish = nil }
                continuation.resume(with: result)
            }

            // Testing `stopped` and publishing `finish` have to be one critical
            // section. Split in two, a stop() landing between them sets the
            // flag, finds nothing to settle, and cancels the listener -- and
            // the handler installed a moment later never hears about a cancel
            // that already happened, so the caller waits forever.
            let alreadyStopped = lock.withLock { () -> Bool in
                if stopped { return true }
                startupFinish = finish
                return false
            }
            if alreadyStopped {
                finish(.failure(StartupError.cancelledBeforeReady))
                return
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // A ready listener with no port is not a working listener.
                    // Reporting 0 as success wrote `"port": 0` into the session
                    // file, and the runtime then dialled port 0 forever without
                    // either side saying anything.
                    if let port = listener.port?.rawValue, port != 0 {
                        finish(.success(port))
                    } else {
                        finish(.failure(StartupError.noPortAssigned))
                    }
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    // stop() before the listener came up. Nothing will resume
                    // this otherwise, and start() would stay suspended for the
                    // lifetime of the process.
                    finish(.failure(StartupError.cancelledBeforeReady))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        lock.withLock { _port = bound }
        return bound
    }

    public func stop() {
        let pendingStart = lock.withLock { () -> (@Sendable (Result<UInt16, Error>) -> Void)? in
            stopped = true
            defer { startupFinish = nil }
            return startupFinish
        }
        pendingStart?(.failure(StartupError.cancelledBeforeReady))

        listener.cancel()
        for peer in lock.withLock({ Array(peers.values) }) { peer.connection.cancel() }
        lock.withLock { peers.removeAll(); sessionPeer = nil; session = nil; mismatched = nil }
        failAllPending(IPCError.disconnected)
    }

    // MARK: - Connection lifecycle

    /// One accepted socket, with its own buffer.
    ///
    /// Per connection rather than one shared buffer, because a connection that
    /// has not authenticated is now allowed to exist alongside the session --
    /// and two streams framed against one buffer would interleave.
    /// Unchecked because every field is only ever touched under the server's
    /// own lock, the same discipline the fields it replaced had.
    private final class Peer: @unchecked Sendable {
        let id: UInt64
        let connection: NWConnection
        var buffer = Data()
        /// How far into `buffer` the newline search has already looked.
        ///
        /// Without it every read re-scanned the whole accumulation: 32 MiB of
        /// newline-free bytes cost 61 seconds at 100% of a core, on the same
        /// serial queue that fires reply handlers and request timeouts, so a
        /// half-millisecond save became a 32-second stall and then a poisoned
        /// session.
        var scanned = 0

        init(id: UInt64, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    /// The largest a single message may be before the connection is dropped.
    ///
    /// A peer that never sends a newline would otherwise grow this buffer until
    /// the machine gave out. Every real message is a few hundred bytes; the
    /// largest carries a list of declaration names.
    private static let messageLimit = 1 << 20

    private func accept(_ incoming: NWConnection) {
        // Accepting is no longer the same thing as becoming the session.
        //
        // It used to be: an incoming connection cleared `session`, failed every
        // request in flight, and took the slot before a single byte was read.
        // So any local process -- a port scan, a stray `nc`, a second `watch`
        // -- ended the developer's session and produced "relaunch the app" for
        // an app that was healthy and mid-answer. The token check happened far
        // too late to prevent it. Nothing here touches the session now; the
        // hello does, once it proves it came from the app.
        let peer: Peer = lock.withLock {
            connectionGeneration += 1
            let peer = Peer(id: connectionGeneration, connection: incoming)
            peers[peer.id] = peer
            return peer
        }

        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.handleDisconnect(peer.id)
            default: break
            }
        }
        incoming.start(queue: queue)
        receive(on: peer)
    }

    /// Only the session's own teardown counts.
    ///
    /// Without the tag, an app that crashed mid-patch and then relaunched could
    /// have its old socket finish cancelling *after* the new one had said
    /// hello, and the stale teardown would wipe the fresh session and fail its
    /// request. The daemon then reported "no app is connected" for every
    /// subsequent save, permanently, because the runtime only sends hello on
    /// connect and its socket was perfectly healthy.
    private func handleDisconnect(_ id: UInt64) {
        let wasSession = lock.withLock { () -> Bool in
            peers[id] = nil
            // The explanation goes with the peer that needed explaining. Kept
            // past its own socket, it outlived the problem: with nothing
            // connected at all, saves still reported a version mismatch.
            if mismatched?.peer == id { mismatched = nil }
            guard sessionPeer == id else { return false }
            sessionPeer = nil
            session = nil
            return true
        }
        guard wasSession else { return }

        // Anything still in flight will never be answered by a socket that is
        // gone. Leaving those continuations suspended is what turned an app
        // crash into a permanently wedged daemon.
        failAllPending(IPCError.disconnected)
        onDisconnect?()
    }

    private func receive(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Bytes from a socket that has already gone must not be framed
            // against a buffer nobody is reading.
            guard self.lock.withLock({ self.peers[peer.id] != nil }) else { return }

            if let data, !data.isEmpty {
                let overflowed = self.lock.withLock { () -> Bool in
                    peer.buffer.append(data)
                    return peer.buffer.count > Self.messageLimit
                }
                if overflowed {
                    self.onEvent?("dropped a connection that sent \(Self.messageLimit) bytes without a complete message")
                    peer.connection.cancel()
                    self.handleDisconnect(peer.id)
                    return
                }
                self.drainLines(from: peer)
            }
            if isComplete || error != nil {
                self.handleDisconnect(peer.id)
                return
            }
            self.receive(on: peer)
        }
    }

    private func drainLines(from peer: Peer) {
        while true {
            let line: Data? = lock.withLock {
                // Resume the search where the last one stopped: everything
                // before `scanned` has already been looked at and holds no
                // newline.
                let searchStart = peer.buffer.index(peer.buffer.startIndex, offsetBy: peer.scanned)
                guard let index = peer.buffer[searchStart...].firstIndex(of: 0x0A) else {
                    peer.scanned = peer.buffer.count
                    return nil
                }
                let line = peer.buffer[peer.buffer.startIndex..<index]
                peer.buffer = peer.buffer[peer.buffer.index(after: index)...]
                peer.scanned = 0
                return Data(line)
            }
            // A blank line is not the end of the buffer: skip it and keep
            // draining, or every message queued behind it waits for the next
            // read that may never come.
            guard let line else { return }
            if line.isEmpty { continue }
            handle(line: line, from: peer)
        }
    }

    private func handle(line: Data, from peer: Peer) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            onEvent?("ignored an unparseable message")
            return
        }
        guard envelope.protocolVersion == EmberProtocol.version else {
            // Section 11.2: a version mismatch fails with a clear diagnostic
            // rather than by misreading the payload.
            onEvent?("protocol version \(envelope.protocolVersion) from the runtime, expected \(EmberProtocol.version); upgrade one side")
            // Remembered, because for a *hello* the settle above has nothing
            // to settle: no session is ever created, and every later save then
            // failed as "no app is connected -- restart the app". Restarting
            // cannot fix a version mismatch, and this is the ordinary case
            // after the daemon is updated and the app is not rebuilt.
            //
            // Both conditions are load-bearing, and both were missing. The
            // guard runs before the type switch and before the token check, so
            // without them *any* envelope from *any* unauthenticated socket set
            // this: one stray `loadResult` at an old version, and a healthy
            // session was described to the developer as needing a rebuild. That
            // is the invariant `accept()` exists to hold -- nothing decides what
            // the daemon says about the session until it has proved it came
            // from the app -- and this had quietly reversed it.
            //
            // A hello is the only message that could have created a session, so
            // it is the only one whose version explains the absence of one. And
            // with a session already in hand there is nothing to explain: the
            // old runtime that keeps redialling after a rebuild would otherwise
            // re-poison this on every redial.
            if envelope.type == "hello" {
                lock.withLock {
                    if sessionPeer == nil {
                        mismatched = (peer.id, envelope.protocolVersion)
                    }
                }
            }
            // And settles whatever was waiting on it. Dropping the reply left
            // the request to burn its whole ten-second timeout and then fail as
            // "the app did not answer", which ends the session -- for a runtime
            // that answered at once, and whose answer said exactly what was
            // wrong. The diagnostic and the outcome should not disagree.
            settle(envelope.requestId,
                   with: .failure(IPCError.versionMismatch(envelope.protocolVersion)))
            return
        }

        switch envelope.type {
        case "hello":
            guard let hello = try? envelope.decode(Hello.self) else {
                onEvent?("could not read the runtime's hello; the two sides' protocol types have drifted")
                return
            }
            // The session file lives in the app's own container, so presenting
            // its token is evidence the connection came from the app. Without
            // this, any local process could take the session and answer for it,
            // and every patch after that would be reported as applied to a
            // process that never saw it.
            guard hello.token == token else {
                onEvent?("refused a connection that did not present the session token")
                peer.connection.cancel()
                handleDisconnect(peer.id)
                return
            }
            // Authenticated, so this peer becomes the session and whatever held
            // it before is superseded. The order matters: the old socket goes
            // first, then anything it was carrying is settled, and only then is
            // the new session announced.
            // A runtime this daemon can read has arrived, so the version it
            // could not read is no longer the reason there is no session.
            // Left standing, it outlived the problem: after the developer
            // rebuilt and relaunched, quitting the app reported "rebuild it"
            // instead of "no app is connected" -- sending them round the loop
            // they had just escaped.
            lock.withLock { mismatched = nil }

            let superseded: (peer: Peer, hadSession: Bool)? = lock.withLock {
                guard let previous = sessionPeer, previous != peer.id,
                      let old = peers[previous] else {
                    sessionPeer = peer.id
                    session = Session(hello: hello, connectedAt: Date())
                    return nil
                }
                peers[previous] = nil
                sessionPeer = peer.id
                let hadSession = session != nil
                session = Session(hello: hello, connectedAt: Date())
                return (old, hadSession)
            }
            if let superseded {
                superseded.peer.connection.cancel()
                failAllPending(IPCError.disconnected)
                if superseded.hadSession { onDisconnect?() }
            }
            onConnect?(hello)
        default:
            settle(envelope.requestId, with: .success(envelope))
        }
    }

    // MARK: - Requests

    public enum StartupError: Error, CustomStringConvertible {
        case noPortAssigned
        case cancelledBeforeReady

        public var description: String {
            switch self {
            case .noPortAssigned: "the listener came up without a port"
            case .cancelledBeforeReady: "the listener was stopped before it was ready"
            }
        }
    }

    public enum IPCError: Error, CustomStringConvertible {
        /// The request never left the daemon.
        case notConnected
        /// The request was sent and the socket went away before an answer.
        case disconnected
        /// The request was sent and nothing came back in time.
        case timedOut
        /// The request was sent and the answer was in a protocol this daemon
        /// does not read.
        case versionMismatch(Int)
        /// The request could not be handed to the socket.
        case sendFailed(String)

        public var description: String {
            switch self {
            case .notConnected: "no app is connected"
            case .disconnected: "the app went away before answering"
            case .timedOut: "the app did not answer"
            case .versionMismatch(let version):
                "the app speaks protocol \(version) and this daemon speaks \(EmberProtocol.version); upgrade one side"
            case .sendFailed(let reason): "the request could not be sent: \(reason)"
            }
        }
    }

    /// Settles a pending request exactly once, whoever gets there first: the
    /// reply, the timeout, a send failure, or a disconnect.
    ///
    /// The removal is what makes it exactly-once, so every path must go through
    /// here rather than resuming a continuation it happens to hold.
    private func settle(_ requestId: String, with result: Result<Envelope, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: requestId) }
        continuation?.resume(with: result)
    }

    private func failAllPending(_ error: Error) {
        let outstanding = lock.withLock { () -> [CheckedContinuation<Envelope, Error>] in
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        for continuation in outstanding { continuation.resume(throwing: error) }
    }

    /// Sends a request and waits for the reply carrying the same requestId.
    ///
    /// The timeout is a scheduled eviction rather than a sibling task racing
    /// the continuation inside a task group. That earlier shape did not work:
    /// when the timeout won, the group cancelled the waiting child and then
    /// waited for it to finish, but cancelling a task does not resume a
    /// `withCheckedThrowingContinuation`, so the call hung forever instead of
    /// timing out -- and because `watch` awaits each save in turn, one hang
    /// silently stopped the daemon from processing anything else.
    public func request<P: Codable, R: Codable>(type: String, payload: P, expecting: R.Type,
                                                timeout: Duration = .seconds(10)) async throws -> R {
        // One snapshot: the connection and the session it belongs to have to
        // be the same peer, and read separately they need not be.
        guard let connection = lock.withLock({ () -> NWConnection? in
            guard let id = sessionPeer, session != nil else { return nil }
            return peers[id]?.connection
        }) else {
            // A runtime that spoke the wrong version is connected but never
            // became the session. Saying which it is turns an unfixable
            // "restart the app" into "rebuild it".
            if let version = lock.withLock({ mismatched?.version }) {
                throw IPCError.versionMismatch(version)
            }
            throw IPCError.notConnected
        }

        let envelope = try Envelope(type: type, payload: payload)
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18

        let reply: Envelope = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[envelope.requestId] = continuation }

            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.settle(envelope.requestId, with: .failure(IPCError.timedOut))
            }

            do {
                let line = try envelope.encodedLine()
                connection.send(content: line, completion: .contentProcessed { [weak self] error in
                    // Discarded, this used to be. A request sent into a
                    // cancelled socket failed instantly and silently, and the
                    // caller waited out the whole timeout to be told "the app
                    // did not answer" -- which ends the session, where a send
                    // failure does not.
                    guard let error else { return }
                    self?.settle(envelope.requestId,
                                 with: .failure(IPCError.sendFailed("\(error)")))
                })
            } catch {
                settle(envelope.requestId, with: .failure(error))
            }
        }

        return try reply.decode(R.self)
    }
}
