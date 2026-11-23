import Foundation
import EmberCore
import EmberDaemon
import EmberGen

public enum Watch {
    public static func run(
        context originalContext: BuildContext,
        workDirectory: URL,
        session: Lifecycle.Session? = nil,
        rebuildCommand: String? = nil,
        rebuildDirectory: URL? = nil,
        rebuildTimeout: TimeInterval = 300,
        json: Bool = false,
        startupProgress: Lifecycle.StartupProgress? = nil,
        onReady: ((SimulatorSelection?) throws -> Void)? = nil
    ) async throws {
        let output = WatchOutput(json: json)
        let startupProgress = json ? nil : startupProgress
        startupProgress?.report("checking build product")
        try validatePhysicalDevice(originalContext)

        // `doctor` checks this and `watch` did not, so pointing it at a
        // product that had never been built started a normal-looking session
        // against a binary that does not exist -- and the first save blamed the
        // *package* setting, because the inventory cannot tell "file missing"
        // from "file exports nothing".
        guard FileManager.default.fileExists(atPath: originalContext.linkTarget) else {
            let hint = originalContext.xcodeSourceTargets != nil
                ? "\n\n\(XcodeProject.derivedDataPathHint)"
                : ""
            throw EmberError(
                stage: .watch, subject: (originalContext.linkTarget as NSString).lastPathComponent,
                reason: """
                    there is no binary at \(originalContext.linkTarget).

                    A patch is compiled and linked against the built product, so the app \
                    has to have been built for this configuration before it can be \
                    patched. Build it, then start watching again.\(hint)
                    """,
                recovery: .rebuild)
        }

        // Validate the build before claiming the destination. Use the resolved
        // UDID for every publication and patch, even if the booted set changes.
        let roots = originalContext.sourceRoots.map { URL(fileURLWithPath: $0) }
        let excluded = originalContext.unwatchedSourcePaths.map { URL(fileURLWithPath: $0) }
        let sourceFilter = SourcePathFilter(excluding: originalContext.excludedSourcePaths.map { URL(fileURLWithPath: $0) })
        let buildOutputs = SourcePathFilter(excluding: originalContext.buildOutputPaths.map { URL(fileURLWithPath: $0) })
        var resolver = ModuleResolver(
            context: originalContext,
            cacheDirectory: workDirectory.appendingPathComponent("package-manifest-cache", isDirectory: true))
        var testSources: Set<URL> = []
        let manifest = BuildSourceManifest(context: originalContext)
        startupProgress?.report("capturing source snapshot")
        let snapshot = try await manifest.snapshot { url in
            guard resolver.isTestSource(url) else { return false }
            testSources.insert(url)
            return true
        }
        startupProgress?.report("validating source manifest and Mach-O UUIDs")
        let verifiedUUIDs = try manifest.validate(snapshot) { resolver.isTestSource($0) }
        if verifiedUUIDs == nil {
            let message = """
                [WATCH] warning: no build source manifest at \(manifest.url.path).
                  Edits between the build and watcher startup cannot be verified.
                  For optional source recording, see "Scheme actions (optional)" in README.md.
                """
            output.warning(message)
        }

        startupProgress?.report("selecting destination")
        let selection = try SimulatorSelection.resolve(context: originalContext)
        if let warning = selection?.warning { output.warning(warning) }
        var selectedContext = originalContext
        selectedContext.simulatorIdentifier = selection?.identifier
        let context = selectedContext
        let ownership = try selection.map {
            try SimulatorOwnership.acquire(simulator: $0.identifier, bundle: context.bundleIdentifier,
                                           owner: Lifecycle.watcherOwner(session: session))
        }
        if let warning = ownership?.warning { output.warning(warning) }
        defer { withExtendedLifetime(ownership) {} }

        startupProgress?.report("preparing IPC listener and source baselines")
        let server = try IPCServer()
        defer { server.stop() }
        let coordinator = PatchCoordinator(
            context: context, server: server, workDirectory: workDirectory, sourceResolver: resolver)
        startupProgress?.report("evaluating package compiler settings and priming source baselines")
        let preparation = await coordinator.primeBaselines(from: snapshot, buildUUIDs: verifiedUUIDs)
        func reportSourceDiagnostics(_ preparation: PatchCoordinator.SourcePreparation) {
            for diagnostic in preparation.diagnostics { output.warning("[WATCH] source module: \(diagnostic)") }
        }
        reportSourceDiagnostics(preparation)
        let watcher = FileWatcher(
            roots: roots, excluding: excluded, excludingFiles: Array(testSources.union(preparation.testSources)))
        watcher.prime(from: snapshot)
        defer { watcher.stop() }
        let watchedBuildUUID = BuildUUID(binary: context.linkTarget)

        server.shouldAcceptHello = { hello in
            let matchesPublishedUUIDs = hello.expectedBuildUUIDs
                == watchedBuildUUID.current()
            if hello.buildIdentity == context.identity
                && (!hello.buildMatchesProcess || !matchesPublishedUUIDs) {
                // The identity matched and the process still is not this build.
                // Module, triple, SDK and compiler version are equal across
                // rebuilds; only the linker UUID is not, and only the process
                // can answer for it.
                let message = """
                connected  pid \(hello.processId), but this is not the build being watched

                  The app was built again after it launched, so patches would be
                  linked against a binary it is not running. Relaunch it.
                """
                output.report(.connectionRefused(processId: hello.processId, message: message)) { print(message) }
                return false
            }
            if hello.buildIdentity != context.identity {
                // Section 6.3: refuse to patch a process built differently from
                // the sources being watched.
                let message = """
                connected  pid \(hello.processId), but the build identity does not match

                  running   \(hello.buildIdentity)
                  watching  \(context.identity)

                Rebuild the app from these sources before editing.
                """
                output.report(.connectionRefused(processId: hello.processId, message: message)) { print(message) }
                return false
            }
            return true
        }
        server.onConnect = { hello in
            // Carries the pid: a reconnect from the same process is not a
            // restart, and clearing on one would resume patching exactly the
            // process the flag exists to stop patching.
            Task { await coordinator.sessionDidConnect(hello: hello) }
            output.report(.connected(processId: hello.processId, bundleIdentifier: hello.moduleName)) {
                print("connected  pid \(hello.processId), \(hello.moduleName)")
            }
        }
        server.onDisconnect = {
            output.report(.disconnected) { print("disconnected; waiting for the app to reconnect") }
        }
        server.onEvent = { diagnostic in
            switch diagnostic {
            case .warning(let message):
                output.warning(message)
            case .connectionRefused(let message):
                output.report(.connectionRefused(processId: nil, message: message)) { print(message) }
            }
        }
        startupProgress?.report("starting IPC listener")
        let port = try await server.start()

        startupProgress?.report(context.deviceIdentifier != nil
            ? "publishing session through CoreDevice"
            : "publishing Simulator session (simctl get_app_container)")
        try await coordinator.announceSession { url in
            if let selection, let owner = SimulatorOwnership.previousOwner(at: url) {
                throw SimulatorOwnership.Conflict(simulator: selection.identifier,
                                                  bundle: context.bundleIdentifier, owner: owner)
            }
        }

        if !json {
            print("watching \(context.sourceRoots.joined(separator: ", "))")
            if !context.buildOutputPaths.isEmpty {
                print("ignoring Xcode build outputs: \(context.buildOutputPaths.joined(separator: ", "))")
            }
            if let device = context.deviceIdentifier {
                print("targeting physical device \(device) through CoreDevice")
            } else if let simulator = context.simulatorIdentifier {
                print("targeting simulator \(simulator) on 127.0.0.1:\(port)")
            } else {
                print("listening on 127.0.0.1:\(port)")
            }
            print("")
        }

        // While nothing is connected, keep republishing where to dial. On a
        // physical device a slower status heartbeat notices a reinstall, which
        // moves the app to a new container, before republishing there.
        let reannounce = Task.detached {
            defer { withExtendedLifetime(ownership) {} }
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
                guard !Task.isCancelled else { break }

                if context.deviceIdentifier != nil {
                    do {
                        physicalConnected = try await coordinator.maintainPhysicalSession()
                        consecutiveFailures = 0
                    } catch {
                        physicalConnected = false
                        consecutiveFailures += 1
                        if consecutiveFailures == 1 {
                            output.warning("cannot reach the app's container: \(error)")
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
                        output.warning("cannot reach the app's container: \(error)")
                    }
                }
            }
        }
        defer { reannounce.cancel() }

        startupProgress?.report("starting file watcher")
        var termination: TerminationSignals?
        let rebuildRunner = RebuildCommand.Runner()
        let changes = AsyncStream<[FileWatcher.Change]> { continuation in
            watcher.start(onScanFailure: { failure in
                let retry = "No source changes will be applied until a complete scan succeeds; retrying."
                let reason = "\(failure.description)\n\n\(retry)"
                output.report(.error(EmberError(
                    stage: .watch, subject: "source roots", reason: reason, recovery: .retry))
                ) {
                    print("")
                    print("[WATCH] source roots")
                    print(failure.description)
                    print(retry)
                    print("")
                }
                Task {
                    await coordinator.reportToRuntime(RuntimeLogMessage(
                        level: .error,
                        message: "[WATCH] source roots\n\(reason)"))
                }
            }) { continuation.yield($0) }
            termination = TerminationSignals {
                rebuildRunner.cancel()
                continuation.finish()
            }
        }
        defer { termination?.cancel() }
        startupProgress?.report("writing readiness record")
        try onReady?(selection)
        startupProgress?.report("watcher ready")
        output.report(.started(sourceRoots: context.sourceRoots, buildOutputPaths: context.buildOutputPaths,
                               port: port, simulator: context.simulatorIdentifier, device: context.deviceIdentifier))
        defer { output.finish() }

        var removalGuard = RemovalGuard()

        func recoverByRebuilding(_ failure: EmberError) async -> Bool {
            guard RebuildCommand.shouldRun(for: failure),
                  let rebuildCommand else { return false }
            let previousProcess = await coordinator.connectedProcessID()
            let previousBuildUUIDs = Set(await coordinator.currentBuildUUIDs())
            let directory = rebuildDirectory
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

            output.report(.rebuildStarted(directory: directory.path)) {
                print("automatic rebuild requested; running in \(directory.path):")
                print("  \(rebuildCommand)")
                print("")
            }
            do {
                var attempt = 0
                while attempt < 3 {
                    try rebuildRunner.throwIfStopping()
                    attempt += 1
                    let before = try await coordinator.captureSources(
                        from: roots, excluding: sourceFilter, ignoring: buildOutputs)
                    let beforeUUIDs = Set(await coordinator.currentBuildUUIDs())
                    try await rebuildRunner.run(
                        rebuildCommand, in: directory, output: json ? FileHandle.standardError : nil)
                    try rebuildRunner.throwIfStopping()
                    let built = try await coordinator.captureSources(
                        from: roots, excluding: sourceFilter, ignoring: buildOutputs)
                    let rebuiltUUIDs = Set(await coordinator.currentBuildUUIDs())
                    guard !rebuiltUUIDs.isEmpty, rebuiltUUIDs != beforeUUIDs,
                          rebuiltUUIDs != previousBuildUUIDs else {
                        throw RebuildRecoveryError.binaryDidNotChange
                    }

                    if built != before {
                        let message = "sources changed during the rebuild; rerunning with the latest snapshot"
                        output.report(.warning(message)) {
                            print(message)
                            print("")
                        }
                        continue
                    }

                    // A reinstall moves the container. Publish the current
                    // binary UUIDs there before waiting for the relaunched runtime.
                    try await coordinator.announceSession()
                    await coordinator.refreshRuntimeSession()
                    let deadline = Date().addingTimeInterval(rebuildTimeout)
                    var replacement: Int32?
                    repeat {
                        try rebuildRunner.throwIfStopping()
                        if context.deviceIdentifier != nil {
                            _ = try? await coordinator.maintainPhysicalSession()
                        }
                        if let process = await coordinator.currentBuildProcessID(),
                           process != previousProcess {
                            replacement = process
                            break
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    } while Date() < deadline

                    guard let replacement else {
                        throw RebuildRecoveryError.relaunchTimedOut(rebuildTimeout)
                    }

                    try rebuildRunner.throwIfStopping()
                    let current = try await coordinator.captureSources(
                        from: roots, excluding: sourceFilter, ignoring: buildOutputs)
                    if current != built {
                        let message = "sources changed while the rebuilt app was launching; rebuilding again"
                        output.report(.warning(message)) {
                            print(message)
                            print("")
                        }
                        continue
                    }

                    // Commit the exact content proven stable around the build.
                    // Do not re-prime the live watcher: buffered events then
                    // remain available for an edit racing this final commit.
                    if Set(await coordinator.currentBuildUUIDs()) != rebuiltUUIDs {
                        throw RebuildRecoveryError.binaryDidNotChange
                    }
                    let preparation = await coordinator.resetAfterRebuild(to: built, buildUUIDs: Array(rebuiltUUIDs))
                    reportSourceDiagnostics(preparation)
                    output.report(.rebuildCompleted(processId: replacement)) {
                        print("automatic rebuild complete; watching pid \(replacement) from a fresh baseline")
                        print("")
                    }
                    await coordinator.reportToRuntime(RuntimeLogMessage(
                        level: .success,
                        message: "Automatic rebuild complete. Hot reload resumed from a fresh baseline."))
                    return true
                }
                throw RebuildRecoveryError.sourcesDidNotSettle
            } catch is CancellationError {
                return false
            } catch {
                let message = "automatic rebuild failed: \(error)"
                let action = "Fix the rebuild command or rebuild and relaunch the app manually."
                output.report(.rebuildFailed(message + "\n" + action)) {
                    print(message)
                    print(action)
                    print("")
                }
                return false
            }
        }

        for await batch in changes {
            var guardedBatch: [FileWatcher.Change] = []
            for change in batch {
                if change.kind == .removed,
                   !(await coordinator.hasBaseline(for: change.url)) {
                    await coordinator.discardRemovedSourceWithoutBaseline(change.url)
                    continue
                }
                guardedBatch.append(change)
            }
            if let error = removalGuard.check(guardedBatch) {
                output.report(.rejection(error)) {
                    print("")
                    print(error.description)
                    print("")
                }
                await coordinator.reportToRuntime(RuntimeLogMessage(
                    level: .warning, message: error.description))
                if await recoverByRebuilding(error) {
                    removalGuard = RemovalGuard()
                }
                continue
            }
            let added = Set(guardedBatch.filter { $0.kind == .added }.map(\.url))
            switch await coordinator.handle(changes: guardedBatch.map(\.url), added: added) {
                case .ignored:
                    continue
                case .rejected(let error):
                    output.report(.rejection(error)) {
                        print("")
                        print(error.description)
                        print("")
                    }
                    await coordinator.reportToRuntime(RuntimeLogMessage(
                        level: .error, message: error.description))
                    if await recoverByRebuilding(error) {
                        removalGuard = RemovalGuard()
                    }
                case .sessionUncertain(let cause):
                    // Repeated on every save rather than said once and
                    // forgotten: the developer is editing, watching nothing
                    // happen, and the reason scrolled off some time ago.
                    let message = """
                    Not patching: this process cannot be described any more.

                    \(cause.stage.rawValue) failed earlier and the patch may
                    have been partly applied, so anything reported after it
                    would be a guess. Relaunch the app; the daemon reconnects
                    on its own and starts a fresh session.

                    The failure was:
                    \(cause.reason)
                    """
                    output.report(.sessionUncertain(cause)) {
                        print("")
                        print(message)
                        print("")
                    }
                    await coordinator.reportToRuntime(RuntimeLogMessage(
                        level: .error, message: message))
                case .applied(let generation, let declarations, let carried, let verified,
                              let registered, let refreshed, let oneShot, let timeline):
                    let report = ReloadReport(
                        generation: generation, declarations: declarations, carried: carried,
                        verified: verified, registered: registered, refreshed: refreshed,
                        oneShot: oneShot, timeline: timeline)
                    let message = output.reportReload(report, summary: timeline.summary())
                    await coordinator.reportToRuntime(message)
            }
        }
    }

    enum RebuildRecoveryError: Error, CustomStringConvertible {
        case relaunchTimedOut(TimeInterval)
        case sourcesDidNotSettle
        case binaryDidNotChange

        var description: String {
            switch self {
            case .relaunchTimedOut(let timeout):
                "the rebuild command finished, but no new app process running the rebuilt binary connected within \(String(format: "%.0f", timeout)) seconds"
            case .sourcesDidNotSettle:
                "sources kept changing across three rebuild attempts; waiting for a manual rebuild avoids adopting an unbuilt baseline"
            case .binaryDidNotChange:
                "the rebuild command did not produce a new Mach-O UUID; refusing to adopt source that the running binary may not contain"
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
