import Foundation
import SpliceCore
import SpliceDaemon
import SpliceGen

public enum Watch {
    public static func run(context: BuildContext) async throws {
        let roots = context.sourceRoots.map { URL(fileURLWithPath: $0) }
        let work = URL(fileURLWithPath: ".splice/patches")

        let server = try IPCServer()
        let coordinator = PatchCoordinator(context: context, server: server, workDirectory: work)

        server.onConnect = { hello in
            // Carries the pid: a reconnect from the same process is not a
            // restart, and clearing on one would resume patching exactly the
            // process the flag exists to stop patching.
            Task { await coordinator.sessionDidConnect(processId: hello.processId) }
            if hello.buildIdentity == context.identity {
                print("connected  pid \(hello.processId), \(hello.moduleName)")
            } else {
                // Section 6.3: refuse to patch a process built differently from
                // the sources being watched.
                print("""
                connected  pid \(hello.processId), but the build identity does not match

                  running   \(hello.buildIdentity)
                  watching  \(context.identity)

                Rebuild the app from these sources before editing.
                """)
            }
        }
        server.onDisconnect = { print("disconnected; waiting for the app to reconnect") }
        server.onEvent = { print($0) }
        let port = try await server.start()

        await coordinator.primeBaselines(from: roots)
        try await coordinator.announceSession()

        let watcher = FileWatcher(roots: roots)
        watcher.prime()

        if ClassifierPolicy.fromEnvironment.allowOpaqueResultTypes {
            print("""
            SPLICE_EXPERIMENTAL_SWIFTUI is set.

            Declarations returning an opaque result type will be patched. For
            `some View` that is safe and useless: the patch loads and SwiftUI
            never calls it, so the reload is reported as successful and nothing
            on screen changes. For any other `some P` it is undefined behaviour.
            This exists to continue the spike in DESIGN.md 13, not to be used.

            """)
        }

        print("watching \(context.sourceRoots.joined(separator: ", "))")
        print("listening on 127.0.0.1:\(port)")
        print("")

        // While nothing is connected, keep republishing where to dial. A
        // reinstall moves the app to a new container, and the session file in
        // the old one is unreachable from the new process -- so without this
        // the daemon waits forever for a connection the app cannot make.
        let reannounce = Task.detached {
            // Detached because announceSession runs `simctl`, measured at about
            // 94 ms, and doing that on the coordinator every two seconds would
            // make a save landing in that window queue behind it.
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let backoff = min(2 << min(consecutiveFailures, 4), 60)
                try? await Task.sleep(for: .seconds(consecutiveFailures == 0 ? 2 : backoff))
                guard server.currentSession == nil else {
                    consecutiveFailures = 0
                    continue
                }
                do {
                    try await coordinator.announceSession()
                    consecutiveFailures = 0
                } catch {
                    // Reported once, then backed off. Swallowing it hid exactly
                    // the case this loop exists for: an app deleted from the
                    // simulator, where the daemon otherwise waits in silence.
                    consecutiveFailures += 1
                    if consecutiveFailures == 1 {
                        print("cannot reach the app's container: \(error)")
                    }
                }
            }
        }
        defer { reannounce.cancel() }

        let changes = AsyncStream<[URL]> { continuation in
            watcher.start { continuation.yield($0) }
        }

        for await batch in changes {
            for url in batch {
                switch await coordinator.handle(change: url) {
                case .ignored:
                    continue
                case .rejected(let error):
                    print("")
                    print(error.description)
                    print("")
                case .sessionUncertain(let cause):
                    // Repeated on every save rather than said once and
                    // forgotten: the developer is editing, watching nothing
                    // happen, and the reason scrolled off some time ago.
                    print("")
                    print("""
                    Not patching: this process cannot be described any more.

                    \(cause.stage.rawValue) failed earlier and the patch may
                    have been partly applied, so anything reported after it
                    would be a guess. Relaunch the app; the daemon reconnects
                    on its own and starts a fresh session.

                    The failure was:
                    \(cause.reason)
                    """)
                    print("")
                case .applied(let generation, let declarations, let timeline):
                    let count = declarations.count
                    let noun = count == 1 ? "declaration" : "declarations"
                    print("")
                    print(String(format: "hot reloaded %d %@ in %.0f ms  (g%llu)",
                                 count, noun, timeline.totalMs, generation))
                    for name in declarations { print("  \(name)") }
                    print(timeline.summary())
                    print("")
                }
            }
        }
    }
}
