import Foundation
import Network
import os
import SpliceCore

/// Stands in for the in-app runtime so the daemon's half of the protocol can be
/// exercised without a simulator.
///
/// It speaks the wire format directly rather than importing the real runtime,
/// which is compiled into the application's own module. That makes it a second
/// reader of the protocol, and a drift between the two shows up here.
final class FakeRuntime: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.fake-runtime")
    private let lock = NSLock()
    private var buffer = Data()
    private var received: [Envelope] = []

    /// Set to answer requests automatically. Leave nil to stay silent, which is
    /// how a wedged or crashed app behaves.
    var responder: (@Sendable (Envelope) -> (type: String, payload: Data)?)?

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
    }

    /// Resolves on ready, or on any terminal state, or on a deadline.
    ///
    /// Waiting only for `.ready` with no bound meant a connection that failed
    /// or stalled hung the test forever, and swift-testing has no per-test
    /// deadline, so that surfaced as a stuck run with no output at all.
    @discardableResult
    func connect(timeout: Duration = .seconds(5)) async -> Bool {
        let ready = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                let already = resumed.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                if !already { continuation.resume(returning: value) }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.receive()
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Double(timeout.components.seconds)) {
                finish(false)
            }
        }
        return ready
    }

    func disconnect() { connection.cancel() }

    func send(type: String, payload: some Codable, requestId: String = UUID().uuidString) throws {
        let envelope = try Envelope(type: type, requestId: requestId, payload: payload)
        connection.send(content: try envelope.encodedLine(), completion: .contentProcessed { _ in })
    }

    /// Sends bytes verbatim, for framing tests.
    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func envelopes() -> [Envelope] { lock.withLock { received } }

    func waitForEnvelope(timeout: Duration = .seconds(5)) async -> Envelope? {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        while Date() < deadline {
            if let first = lock.withLock({ received.first }) { return first }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.buffer.append(data) }
                self.drain()
            }
            if isComplete || error != nil { return }
            self.receive()
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
            guard let line, !line.isEmpty,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
                if line == nil { return }
                continue
            }
            lock.withLock { received.append(envelope) }
            if let reply = responder?(envelope) {
                let response = Envelope(type: reply.type, requestId: envelope.requestId,
                                        rawPayload: reply.payload)
                if var data = try? JSONEncoder().encode(response) {
                    data.append(0x0A)
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }
        }
    }
}
