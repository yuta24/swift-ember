import Foundation
import SpliceCore
import SpliceDaemon

public enum Watch {
    public static func run(context: BuildContext) async throws {
        let roots = context.sourceRoots.map { URL(fileURLWithPath: $0) }
        let work = URL(fileURLWithPath: ".splice/patches")

        let server = try IPCServer()
        let coordinator = PatchCoordinator(context: context, server: server, workDirectory: work)

        server.onConnect = { hello in
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

        print("watching \(context.sourceRoots.joined(separator: ", "))")
        print("listening on 127.0.0.1:\(port)")
        print("")

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
