import Foundation
import SpliceCore
import SpliceDaemon
import SpliceGen

public enum Watch {
    public static func run(context: BuildContext) async throws {
        let roots = context.sourceRoots.map { URL(fileURLWithPath: $0) }
        let work = URL(fileURLWithPath: ".splice/patches")

        // `doctor` checks this and `watch` did not, so pointing it at a
        // product that had never been built started a normal-looking session
        // against a binary that does not exist -- and the first save blamed the
        // *package* setting, because the inventory cannot tell "file missing"
        // from "file exports nothing".
        guard FileManager.default.fileExists(atPath: context.linkTarget) else {
            throw SpliceError(
                stage: .watch, subject: (context.linkTarget as NSString).lastPathComponent,
                reason: """
                    there is no binary at \(context.linkTarget).

                    A patch is compiled and linked against the built product, so the app \
                    has to have been built for this configuration before it can be \
                    patched. Build it, then start watching again.
                    """,
                recovery: .rebuild)
        }

        let server = try IPCServer()
        let coordinator = PatchCoordinator(context: context, server: server, workDirectory: work)

        server.onConnect = { hello in
            // Carries the pid: a reconnect from the same process is not a
            // restart, and clearing on one would resume patching exactly the
            // process the flag exists to stop patching.
            Task { await coordinator.sessionDidConnect(processId: hello.processId) }
            if hello.buildIdentity == context.identity && !hello.buildMatchesProcess {
                // The identity matched and the process still is not this build.
                // Module, triple, SDK and compiler version are equal across
                // rebuilds; only the linker UUID is not, and only the process
                // can answer for it.
                print("""
                connected  pid \(hello.processId), but this is not the build being watched

                  The app was built again after it launched, so patches would be
                  linked against a binary it is not running. Relaunch it.
                """)
            } else if hello.buildIdentity == context.identity {
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
            // Detached so the wait between attempts is not held on the caller.
            // It does not keep `simctl` off the coordinator: `announceSession`
            // is actor-isolated, so a save landing in that 94 ms window queues
            // behind it either way. The comment here used to claim otherwise.
            // It only runs while nothing is connected, so the window is one a
            // developer is unlikely to be saving into.
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
                case .applied(let generation, let declarations, let carried, let verified,
                              let registered, let refreshed, let oneShot, let timeline):
                    let count = declarations.count
                    let noun = count == 1 ? "declaration" : "declarations"
                    print("")
                    print(String(format: "hot reloaded %d %@ in %.0f ms  (g%llu)",
                                 count, noun, timeline.totalMs, generation))
                    for name in declarations { print("  \(name)") }
                    // Named rather than counted. A carried declaration is one
                    // the patch had to bring with it -- a private helper, or one
                    // that did not exist in the build -- and seeing which is the
                    // difference between "that is why it worked" and a mystery.
                    if !carried.isEmpty {
                        print("  carried: \(carried.joined(separator: ", "))")
                    }
                    // Said only when it is not true. A reload that could not be
                    // confirmed is still a reload, but the developer should know
                    // which kind they are looking at -- the whole reason this
                    // tool refuses SwiftUI `body` is that a reload which lies is
                    // worse than a refusal.
                    if !verified {
                        // Which way the count was wrong, not only that it was.
                        // "Could not count" and "counted more than were asked
                        // for" are different problems and were reported with
                        // the same sentence.
                        if let registered {
                            // "Contributed", not "declared": for an `@objc`
                            // member the evidence is an Objective-C category,
                            // which says the image brought a method and not
                            // that it replaced one.
                            // Always plural: a count below the expected one
                            // ends the session before it reaches here, and the
                            // expected count is never zero, so the smallest
                            // number this line can carry is two.
                            print("  not verified: the image replaced \(registered.counted) declarations "
                                  + "and \(registered.expected) were generated")
                        } else {
                            print("  not verified: the runtime could not read the image's records")
                        }
                    }
                    // What it took to put the change on screen. A UIKit process
                    // is told to lay out again, and a list to reload; without
                    // that the body is replaced in the process and the screen
                    // keeps whatever it drew last.
                    if let refreshed {
                        print("  refreshed: \(refreshed)")
                    }
                    // The entry points a refresh cannot reach on its own. Said
                    // rather than left to be discovered, for the same reason
                    // `some View` is refused outright: an edit that loads and
                    // changes nothing is the worst outcome this tool has.
                    // Grouped by how far out of reach the new body is. A view
                    // controller can be made again inside this process and will
                    // run it; an application delegate cannot, and a relaunch
                    // starts from the built binary with no patch in it -- so
                    // telling someone to make another one would be advice that
                    // does not work.
                    let reachable = oneShot.filter { $0.scope == .instance }
                    let unreachable = oneShot.filter { $0.scope == .process }
                    if !reachable.isEmpty {
                        print("  already ran: \(reachable.map(\.name).joined(separator: ", "))")
                        print("  replaced, but UIKit will not call it again for anything that")
                        print("  already exists; the next instance of that type runs the new body")
                    }
                    if !unreachable.isEmpty {
                        print("  already ran: \(unreachable.map(\.name).joined(separator: ", "))")
                        print("  there is one of these per process, and relaunching starts from the")
                        print("  built binary, so seeing this change takes a build")
                    }
                    print(timeline.summary())
                    print("")
                }
            }
        }
    }
}
