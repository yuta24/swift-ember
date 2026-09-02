import Foundation
import EmberCore
import EmberDaemon
import EmberGen

public enum Watch {
    public static func run(
        context: BuildContext,
        workDirectory: URL,
        onReady: (() throws -> Void)? = nil
    ) async throws {
        try validatePhysicalDevice(context)
        let roots = context.sourceRoots.map { URL(fileURLWithPath: $0) }
        let excluded = context.excludedSourcePaths.map { URL(fileURLWithPath: $0) }
        let sourceFilter = SourcePathFilter(excluding: excluded)

        // `doctor` checks this and `watch` did not, so pointing it at a
        // product that had never been built started a normal-looking session
        // against a binary that does not exist -- and the first save blamed the
        // *package* setting, because the inventory cannot tell "file missing"
        // from "file exports nothing".
        guard FileManager.default.fileExists(atPath: context.linkTarget) else {
            throw EmberError(
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
        defer { server.stop() }
        let coordinator = PatchCoordinator(context: context, server: server, workDirectory: workDirectory)

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

        await coordinator.primeBaselines(from: roots, excluding: sourceFilter)
        try await coordinator.announceSession()

        let watcher = FileWatcher(roots: roots, excluding: excluded)
        defer { watcher.stop() }
        do {
            try watcher.prime()
        } catch let failure as FileWatcher.ScanFailure {
            throw EmberError(
                stage: .watch,
                subject: "source roots",
                reason: "cannot take the initial source snapshot.\n\n\(failure)",
                recovery: .configure)
        }

        print("watching \(context.sourceRoots.joined(separator: ", "))")
        if let device = context.deviceIdentifier {
            print("targeting physical device \(device) through CoreDevice")
        } else if let simulator = context.simulatorIdentifier {
            print("targeting simulator \(simulator) on 127.0.0.1:\(port)")
        } else {
            print("listening on 127.0.0.1:\(port)")
        }
        print("")

        try onReady?()

        // While nothing is connected, keep republishing where to dial. On a
        // physical device a slower status heartbeat notices a reinstall, which
        // moves the app to a new container, before republishing there.
        let reannounce = Task.detached {
            // Detached so the wait between attempts is not held on the caller.
            // It does not keep `simctl` off the coordinator: `announceSession`
            // is actor-isolated, so a save landing in that 94 ms window queues
            // behind it either way. The comment here used to claim otherwise.
            // Simulator publication only runs while disconnected. Physical
            // status checks continue at a lower rate while connected.
            var consecutiveFailures = 0
            var physicalConnected = await coordinator.hasPhysicalProcess
            while !Task.isCancelled {
                let backoff = min(2 << min(consecutiveFailures, 4), 60)
                let normalDelay = context.deviceIdentifier != nil && physicalConnected ? 10 : 2
                try? await Task.sleep(for: .seconds(
                    consecutiveFailures == 0 ? normalDelay : backoff))

                if context.deviceIdentifier != nil {
                    do {
                        physicalConnected = try await coordinator.maintainPhysicalSession()
                        consecutiveFailures = 0
                    } catch {
                        physicalConnected = false
                        consecutiveFailures += 1
                        if consecutiveFailures == 1 {
                            print("cannot reach the app's container: \(error)")
                        }
                    }
                    continue
                }

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

        var termination: TerminationSignals?
        let changes = AsyncStream<[FileWatcher.Change]> { continuation in
            watcher.start(onScanFailure: { failure in
                print("")
                print("[WATCH] source roots")
                print(failure.description)
                print("No source changes will be applied until a complete scan succeeds; retrying.")
                print("")
            }) { continuation.yield($0) }
            termination = TerminationSignals { continuation.finish() }
        }
        defer { termination?.cancel() }

        var removalGuard = RemovalGuard()
        for await batch in changes {
            if let error = removalGuard.check(batch) {
                print("")
                print(error.description)
                print("")
                continue
            }
            for change in batch {
                switch await coordinator.handle(change: change.url) {
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
                    // which kind they are looking at. A reload nobody can
                    // vouch for is the shape this project refuses elsewhere,
                    // and saying so is what keeps it from being one.
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
                            // Records, not declarations: an accessor and an
                            // opaque return each bring one, so the two numbers
                            // are not counts of the same thing and saying
                            // "declarations" made a correct pair look wrong.
                            let plural = registered.expected == 1 ? "was" : "were"
                            print("  not verified: the image carries \(registered.counted) replacement "
                                  + "records and \(registered.expected) \(plural) generated")
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
                    // rather than left to be discovered: an edit that loads and
                    // changes nothing is the outcome this tool exists to avoid
                    // reporting as success.
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

    /// A rename is observed as one removal and one addition. Refuse the whole
    /// poll rather than letting the new path through as an added declaration:
    /// the running binary still contains the old file, and applying only the
    /// added half would report a partial refactor as a reload. Once tripped,
    /// this remains closed until a rebuild starts a new watcher: every batch
    /// skipped while it is closed has already advanced the file watcher's
    /// stamps and cannot be replayed safely from here.
    struct RemovalGuard {
        private var removed: Set<URL> = []

        mutating func check(_ changes: [FileWatcher.Change]) -> EmberError? {
            removed.formUnion(changes.lazy.filter { $0.kind == .removed }.map(\.url))
            return Watch.removalError(for: removed, changeCount: changes.count)
        }
    }

    static func removalError(for missing: Set<URL>, changeCount: Int) -> EmberError? {
        guard !missing.isEmpty else { return nil }

        let removed = missing.sorted { $0.path < $1.path }
        let subject = removed.count == 1
            ? removed[0].lastPathComponent
            : "\(removed.count) source files"
        let paths = removed.map { "  \($0.path)" }.joined(separator: "\n")
        let scope = changeCount == 1 ? "this change" : "this batch"
        return EmberError(
            stage: .classify,
            subject: subject,
            reason: """
                a watched source file was removed or renamed:

                \(paths)

                The running binary still contains declarations from the built file, so \(scope) cannot be applied safely.
                Rebuild, then restart the watcher. The `xcode start` Build post-action restarts it automatically.
                """,
            recovery: .rebuild)
    }

    public static func validatePhysicalDevice(_ context: BuildContext) throws {
        guard context.deviceIdentifier != nil else { return }
        guard context.sdkName == "iphoneos", !context.targetTriple.contains("-simulator") else {
            throw EmberError(stage: .watch, subject: context.moduleName,
                              reason: "--device resolved a simulator build; select the same physical device as the Xcode destination",
                              recovery: .configure)
        }
        guard context.codeSigningIdentity?.isEmpty == false else {
            throw EmberError(stage: .watch, subject: context.moduleName,
                              reason: "physical-device patches require Development signing; configure the Debug build or pass --signing-identity",
                              recovery: .configure)
        }
    }
}
