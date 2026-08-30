// Driver for the case where a call is already suspended when its replacement
// is loaded. The ordinary harness cannot express that ordering because it
// awaits each probe before loading the next image.

import Foundation

private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "waiting for the old invocation to suspend"

    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@main
enum SuspendedAsyncFixtureMain {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        guard CommandLine.arguments.count == 2,
              let patch = CommandLine.arguments.dropFirst().first else {
            print("expected exactly one patch")
            exit(64)
        }

        // A broken continuation or dispatch regression must fail this case
        // rather than leave the entire fixture matrix waiting forever.
        let watchdogState = WatchdogState()
        let watchdog = Task.detached(priority: .high) {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            let stage = watchdogState.current
            guard !Task.isCancelled, stage != "complete" else { return }
            print("fixture-timeout: \(stage)")
            exit(70)
        }
        defer { watchdog.cancel() }

        let suspendedGate = SuspensionGate()
        let inFlight = Task { await suspendedValue(gate: suspendedGate) }

        // Do not load the patch until the old invocation has crossed a real
        // async suspension point and stored its continuation.
        while !(await suspendedGate.isWaiting) {
            await Task.yield()
        }

        watchdogState.update("loading the replacement")
        guard dlopen(patch, RTLD_NOW) != nil else {
            print("load-failed: \(String(cString: dlerror()))")
            exit(2)
        }

        watchdogState.update("waiting for the old invocation to resume")
        await suspendedGate.resume()
        print("g0: \(await inFlight.value)")

        // A gate that starts open lets the second invocation finish without
        // another coordinator while still executing the replacement's await.
        watchdogState.update("waiting for the post-patch invocation")
        let openGate = SuspensionGate(open: true)
        print("g1: \(await suspendedValue(gate: openGate))")
        watchdogState.update("complete")
        watchdog.cancel()
    }
}
