import Foundation
import Network
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
    private var connection: NWConnection?
    private var session: Session?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Envelope, Error>] = [:]

    public let port: UInt16
    public let token: String

    public var onEvent: (@Sendable (String) -> Void)?
    public var onConnect: (@Sendable (Hello) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    public var currentSession: Session? { lock.withLock { session } }

    public init(port: UInt16 = SpliceProtocol.defaultPort) throws {
        self.token = UUID().uuidString
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        self.listener = try NWListener(using: parameters)
        self.port = port
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        lock.withLock { connection }?.cancel()
    }

    // MARK: - Connection lifecycle

    private func accept(_ incoming: NWConnection) {
        // One runtime at a time. A second connection means the app relaunched,
        // so the newer one wins.
        lock.withLock {
            connection?.cancel()
            connection = incoming
            session = nil
            buffer = Data()
        }
        incoming.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.handleDisconnect() }
            if case .failed = state { self?.handleDisconnect() }
        }
        incoming.start(queue: queue)
        receive(on: incoming)
    }

    private func handleDisconnect() {
        let had = lock.withLock { () -> Bool in
            let had = session != nil
            session = nil
            return had
        }
        if had { onDisconnect?() }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.buffer.append(data) }
                self.drainLines()
            }
            if isComplete || error != nil {
                self.handleDisconnect()
                return
            }
            self.receive(on: connection)
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
            guard let line, !line.isEmpty else { return }
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
            guard let hello = try? envelope.decode(Hello.self) else { return }
            lock.withLock { session = Session(hello: hello, connectedAt: Date()) }
            onConnect?(hello)
        default:
            let continuation = lock.withLock { pending.removeValue(forKey: envelope.requestId) }
            continuation?.resume(returning: envelope)
        }
    }

    // MARK: - Requests

    public enum IPCError: Error, CustomStringConvertible {
        case notConnected
        case timedOut

        public var description: String {
            switch self {
            case .notConnected: "no app is connected"
            case .timedOut: "the app did not answer"
            }
        }
    }

    /// Sends a request and waits for the reply carrying the same requestId.
    public func request<P: Codable, R: Codable>(type: String, payload: P, expecting: R.Type,
                                                timeout: Duration = .seconds(10)) async throws -> R {
        guard let connection = lock.withLock({ self.connection }), currentSession != nil else {
            throw IPCError.notConnected
        }

        let envelope = try Envelope(type: type, payload: payload)
        let reply = try await withThrowingTaskGroup(of: Envelope.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock { self.pending[envelope.requestId] = continuation }
                    do {
                        connection.send(content: try envelope.encodedLine(),
                                        completion: .contentProcessed { _ in })
                    } catch {
                        self.lock.withLock { _ = self.pending.removeValue(forKey: envelope.requestId) }
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw IPCError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        return try reply.decode(R.self)
    }
}
