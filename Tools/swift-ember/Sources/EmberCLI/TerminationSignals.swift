import Darwin
import Dispatch

/// Converts terminal and service termination into normal async-stream
/// completion, giving `watch` a chance to stop its listener and remove its PID
/// record instead of leaving a stale session behind.
final class TerminationSignals: @unchecked Sendable {
    private let signals = [SIGINT, SIGTERM]
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping @Sendable () -> Void) {
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for number in signals { signal(number, SIG_DFL) }
    }

    deinit { cancel() }
}
