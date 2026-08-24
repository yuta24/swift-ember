import Foundation
import Network
import os
import SpliceCore

/// The daemon end of the local development channel (DESIGN.md section 11).
///
/// The daemon listens and the runtime dials in, which is what makes
/// reconnection after an app relaunch fall out for free: a new process simply
/// connects again. Loopback only, with a per-session token, so another local
/// process cannot pose as the daemon (PRD.md section 12).
public final class IPCServer: @unchecked Sendable {
    public struct Session: Sendable {
        public let hello: Hello
        public let connectedAt: Date
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.swift-splice.ipc")
    private let lock = NSLock()
    private var stopped = false
    /// Set while `start()` is waiting, so `stop()` can settle it.
    private var startupFinish: (@Sendable (Result<UInt16, Error>) -> Void)?
    private var connection: NWConnection?
    /// Bumped on every accept. `NWConnection.cancel()` is graceful, so a
    /// superseded socket can finish tearing down long after its replacement is
    /// live; the tag is how a late teardown knows it is no longer current.
    private var connectionGeneration: UInt64 = 0
    private var session: Session?
    private var buffer = Data()
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
        lock.withLock { connection }?.cancel()
        failAllPending(IPCError.disconnected)
    }

    // MARK: - Connection lifecycle

    private func accept(_ incoming: NWConnection) {
        // One runtime at a time. A second connection means the app relaunched,
        // so the newer one wins.
        let generation: UInt64 = lock.withLock {
            connection?.cancel()
            connection = incoming
            connectionGeneration += 1
            session = nil
            buffer = Data()
            return connectionGeneration
        }
        // The socket being replaced will never answer. Its teardown is now a
        // no-op for the current generation, so this is the only place left
        // that can settle what it was carrying; without it a request waits out
        // the full timeout while `watch`, which awaits each save in turn,
        // stalls for that whole window.
        failAllPending(IPCError.disconnected)
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.handleDisconnect(generation)
            default: break
            }
        }
        incoming.start(queue: queue)
        receive(on: incoming, generation: generation)
    }

    /// Only the current connection's teardown counts.
    ///
    /// Without the tag, an app that crashed mid-patch and then relaunched could
    /// have its old socket finish cancelling *after* the new one had said
    /// hello, and the stale teardown would wipe the fresh session and fail its
    /// request. The daemon then reported "no app is connected" for every
    /// subsequent save, permanently, because the runtime only sends hello on
    /// connect and its socket was perfectly healthy.
    private func handleDisconnect(_ generation: UInt64) {
        let had = lock.withLock { () -> Bool? in
            guard generation == connectionGeneration else { return nil }
            let had = session != nil
            session = nil
            return had
        }
        guard let had else { return }

        // Anything still in flight will never be answered by a socket that is
        // gone. Leaving those continuations suspended is what turned an app
        // crash into a permanently wedged daemon.
        failAllPending(IPCError.disconnected)
        if had { onDisconnect?() }
    }

    private func receive(on connection: NWConnection, generation: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Bytes from a superseded socket must not land in the current
            // buffer, where they would be framed against someone else's stream.
            guard self.lock.withLock({ generation == self.connectionGeneration }) else { return }

            if let data, !data.isEmpty {
                self.lock.withLock { self.buffer.append(data) }
                self.drainLines()
            }
            if isComplete || error != nil {
                self.handleDisconnect(generation)
                return
            }
            self.receive(on: connection, generation: generation)
        }
    }

    private func drainLines() {
        while true {
            let line: Data? = lock.withLock {
                guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<index]
                buffer = buffer[buffer.index(after: index)...]
                return Data(line)
            }
            // A blank line is not the end of the buffer: skip it and keep
            // draining, or every message queued behind it waits for the next
            // read that may never come.
            guard let line else { return }
            if line.isEmpty { continue }
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            onEvent?("ignored an unparseable message")
            return
        }
        guard envelope.protocolVersion == SpliceProtocol.version else {
            // Section 11.2: a version mismatch fails with a clear diagnostic
            // rather than by misreading the payload.
            onEvent?("protocol version \(envelope.protocolVersion) from the runtime, expected \(SpliceProtocol.version); upgrade one side")
            return
        }

        switch envelope.type {
        case "hello":
            guard let hello = try? envelope.decode(Hello.self) else {
                onEvent?("could not read the runtime's hello; the two sides' protocol types have drifted")
                return
            }
            lock.withLock { session = Session(hello: hello, connectedAt: Date()) }
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

        public var description: String {
            switch self {
            case .notConnected: "no app is connected"
            case .disconnected: "the app went away before answering"
            case .timedOut: "the app did not answer"
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
        guard let connection = lock.withLock({ self.connection }), currentSession != nil else {
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
                connection.send(content: try envelope.encodedLine(),
                                completion: .contentProcessed { _ in })
            } catch {
                settle(envelope.requestId, with: .failure(error))
            }
        }

        return try reply.decode(R.self)
    }
}
