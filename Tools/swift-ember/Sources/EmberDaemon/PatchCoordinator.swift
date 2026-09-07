import Foundation
import EmberCore
import EmberGen

/// Drives one save through the pipeline: classify, generate, compile, deliver,
/// load, report.
///
/// Everything policy-shaped lives here rather than in the runtime, per
/// DESIGN.md section 4.3. The runtime's only decision is whether `dlopen`
/// worked.
public actor PatchCoordinator {
    private struct PreparedChange: Sendable {
        let url: URL
        let current: String
        let index: FileIndex
        let plan: PatchPlan
        let resolution: ModuleResolver.Resolution

        /// A carried declaration already resident in an earlier image changed.
        /// It has no replacement record of its own, but loading its new copy
        /// together with the remembered callers is observable.
        let updatesLoadedContribution: Bool

        var requiresImage: Bool {
            !plan.replacements.isEmpty || updatesLoadedContribution
        }
    }

    private struct PatchContribution: Sendable {
        let url: URL
        let index: FileIndex
        let plan: PatchPlan
    }

    private struct DeferredTarget: Sendable {
        var urls: Set<URL> = []
        var blockers: Set<URL> = []
    }

    private let context: BuildContext
    private let server: IPCServer
    private let compiler: PatchCompiler
    private let simulatorContainer: SimulatorContainer?
    private let physicalDevice: PhysicalDeviceBridge?
    private let resolver: ModuleResolver
    /// Read once per session from the running binary. A rebuild changes it,
    /// and a rebuild means a relaunch, which is a new session.
    private lazy var inventory = inventoryOverride
        ?? ModuleInventory.read(from: context.linkTarget)
    private let inventoryOverride: ModuleInventory?
    /// Unlike the inventory, re-read whenever the binary changes.
    ///
    /// The inventory's excuse for caching -- a rebuild means a relaunch -- is
    /// exactly what this check exists to disprove.
    private let buildUUIDReader: BuildUUID
    private let buildUUIDOverride: [String]?
    private var buildUUIDs: [String] { buildUUIDOverride ?? buildUUIDReader.current() }
    /// Set when a patch may have been partly applied and cleared only by a
    /// fresh process.
    ///
    /// DESIGN.md section 17: a load or registration failure may leave the
    /// process in an uncertain state, and the session should say "restart
    /// recommended" unless recovery is proven. Until this existed the daemon
    /// printed the failure and went on patching a process whose contents it
    /// could no longer describe -- reporting later reloads as successful on
    /// top of a state nobody could vouch for.
    private var uncertain: EmberError?
    /// The process the flag is about. Clearing needs a different one.
    private var uncertainProcess: Int32?
    private var physicalProcessId: Int32?
    /// Suppresses only consecutive duplicates for one running process. A
    /// different message, or an app relaunch with a new pid, makes the same
    /// diagnostic useful again.
    private var lastRuntimeLog: (processId: Int32, log: RuntimeLogMessage)?

    private var baselines: [URL: String] = [:]
    /// Build-time snapshots for sources omitted from file watching. They still
    /// participate in cross-file safety checks because their declarations are
    /// present in the running binary. Keeping their original text also avoids
    /// trusting an ignored on-disk edit that the process has not rebuilt.
    private var excludedSafetyBaselines: [URL: String] = [:]
    /// The baseline's parsed form, kept because it only changes when a patch
    /// lands. Re-parsing it on every save doubled the cost of classification,
    /// which is the one stage that grows with the size of the file being
    /// edited.
    private var baselineIndexes: [URL: FileIndex] = [:]
    /// What each file has already contributed to this session's patches.
    ///
    /// Cleared by nothing: a carried declaration stays only in the patches, so
    /// every later patch for that file has to carry it again. A rebuild ends
    /// the session, which is the only thing that makes it stale.
    private var memories: [URL: SessionMemory] = [:]
    /// Source URLs whose on-disk contents are not represented by the running
    /// process. One target owns one conservative retry unit: later saves are
    /// re-read from disk and folded into it, so no stored source snapshot can
    /// go stale and no declaration moves between competing pending stores.
    private var deferredTargets: [String: DeferredTarget] = [:]
    private var generation: UInt64 = 0

    /// `deliver` exists so the load path can be reached without a simulator.
    ///
    /// Not gratuitous: a test for what happens *after* a load has to get past
    /// the copy into the app container, and without this every such test
    /// stopped at TRANSFER and asserted nothing while passing.
    /// `inventory`, like `deliver`, exists so the stages after it can be
    /// reached without a built application. Both default to reading the real
    /// thing.
    public init(context: BuildContext, server: IPCServer, workDirectory: URL,
                deliver: (@Sendable (URL) throws -> URL)? = nil,
                inventory: ModuleInventory? = nil,
                buildUUIDs: [String]? = nil) {
        self.context = context
        self.server = server
        self.compiler = PatchCompiler(context: context, workDirectory: workDirectory)
        if context.deviceIdentifier == nil {
            self.simulatorContainer = SimulatorContainer(
                bundleIdentifier: context.bundleIdentifier,
                deviceIdentifier: context.simulatorIdentifier)
            self.physicalDevice = nil
        } else {
            self.simulatorContainer = nil
            self.physicalDevice = PhysicalDeviceBridge(context: context, workDirectory: workDirectory)
        }
        self.resolver = ModuleResolver(appModule: context.moduleName)
        self.deliverOverride = deliver
        self.inventoryOverride = inventory
        self.buildUUIDOverride = buildUUIDs
        self.buildUUIDReader = BuildUUID(binary: context.linkTarget)
    }

    private let deliverOverride: (@Sendable (URL) throws -> URL)?

    /// Snapshots the sources as they were when the running binary was built.
    /// Everything afterwards is diffed against this, and the baseline advances
    /// only when a patch actually lands, so a rejected edit stays visible on
    /// the next save instead of being silently absorbed.
    public func primeBaselines(
        from roots: [URL],
        excluding sourceFilter: SourcePathFilter = SourcePathFilter()
    ) {
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // Text only. Parsing every file at startup would cost a large
                // project seconds before the first edit, and most files are
                // never touched in a session.
                let url = url.standardizedFileURL
                let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if sourceFilter.excludes(url) {
                    excludedSafetyBaselines[url] = source
                } else {
                    baselines[url] = source
                }
            }
        }
    }

    /// Publishes where to reach the daemon into the app's container.
    ///
    /// Re-runs the lookup rather than trusting the cache, because the usual
    /// reason to call this again is that the app was reinstalled and now lives
    /// somewhere else. Without that, a reinstall left the session file in the
    /// old container, the app never found it, and the daemon waited for a
    /// connection that could not happen.
    public func announceSession() throws {
        if let physicalDevice {
            try physicalDevice.writeSession(token: server.token,
                                            buildIdentity: context.identity,
                                            buildUUIDs: buildUUIDs)
            if let processId = physicalDevice.connectedProcess() {
                sessionDidConnect(processId: processId)
                physicalProcessId = processId
            }
        } else if let simulatorContainer {
            simulatorContainer.invalidate()
            try simulatorContainer.writeSession(port: server.port, token: server.token,
                                                buildIdentity: context.identity, buildUUIDs: buildUUIDs)
        }
    }

    public var hasPhysicalProcess: Bool { physicalProcessId != nil }

    /// Keeps the file-based device session reachable without copying the
    /// session file on every polling tick. A connected app only needs a cheap
    /// status heartbeat; the session is republished when that heartbeat can no
    /// longer see this watch token, which also covers an app reinstall moving
    /// its data container.
    @discardableResult
    public func maintainPhysicalSession() throws -> Bool {
        guard let physicalDevice else { return false }
        if let processId = physicalDevice.connectedProcess() {
            sessionDidConnect(processId: processId)
            physicalProcessId = processId
            return true
        }

        physicalProcessId = nil
        try physicalDevice.writeSession(token: server.token,
                                        buildIdentity: context.identity,
                                        buildUUIDs: buildUUIDs)
        if let processId = physicalDevice.connectedProcess() {
            sessionDidConnect(processId: processId)
            physicalProcessId = processId
            return true
        }
        return false
    }

    public enum Outcome: Sendable {
        case ignored
        case rejected(EmberError)
        case applied(generation: UInt64, declarations: [String], carried: [String],
                     /// Whether the runtime could count what the image registered.
                     /// False means the reload happened and nothing confirmed it.
                     verified: Bool,
                     /// What the runtime counted, and what it should have been,
                     /// so an unverified reload can say which way the count was
                     /// wrong rather than only that it was. Nil means the
                     /// runtime could not read the image at all.
                     registered: (counted: Int, expected: Int)?,
                     /// What the runtime's UIKit adapter touched to make the
                     /// generation visible, or nil when it touched nothing.
                     refreshed: String?,
                     /// Replaced declarations that UIKit has already called and
                     /// will not call again on its own.
                     oneShot: [OneShotNote],
                     timeline: StageTimeline)
        /// Refused without being examined, because the running process can no
        /// longer be described. Carries the failure that caused it.
        case sessionUncertain(EmberError)
    }

    public var isUncertain: Bool { uncertain != nil }

    /// Mirrors a user-facing watcher result into the running application's
    /// Xcode console. This channel is deliberately best-effort: the daemon's
    /// own log remains canonical, and a display failure cannot change patch
    /// state or poison a session.
    @discardableResult
    public func reportToRuntime(_ log: RuntimeLogMessage) -> Bool {
        do {
            let processId: Int32
            if let physicalDevice {
                // Reporting must not launch a synchronous `devicectl` status
                // probe. Session maintenance and the patch path establish this
                // value; without one, the canonical host log is sufficient.
                guard let connected = physicalProcessId else { return false }
                processId = connected
                if let previous = lastRuntimeLog,
                   previous.processId == processId, previous.log == log {
                    return false
                }
                physicalDevice.sendRuntimeLog(log)
            } else {
                guard let session = server.currentSession else { return false }
                processId = session.hello.processId
                if let previous = lastRuntimeLog,
                   previous.processId == processId, previous.log == log {
                    return false
                }
                try server.send(type: "runtimeLog", payload: log)
            }
            lastRuntimeLog = (processId, log)
            return true
        } catch {
            return false
        }
    }

    /// Called when an app connects, with the pid it reported.
    ///
    /// A reconnect is not a restart. The runtime re-dials whenever its socket
    /// drops -- a suspend and resume in the simulator is enough -- and the same
    /// process coming back says nothing about the state that poisoned the
    /// session. Only a different pid is evidence of a new process, which is
    /// the one state this daemon can vouch for without having watched it
    /// become that way.
    public func sessionDidConnect(processId: Int32) {
        guard uncertain != nil else { return }
        guard processId != uncertainProcess else { return }
        uncertain = nil
        uncertainProcess = nil
    }

    /// Records the failure as the reason the session can no longer be
    /// described, and returns it so the call site still throws normally.
    ///
    /// Deliberately not derived from `recovery` or from the stage. "Could not
    /// find the app container" also recommends a restart and leaves the
    /// process untouched; only the paths where a load may have half-happened
    /// come through here.
    private func poison(_ error: EmberError) -> EmberError {
        uncertain = error
        uncertainProcess = server.currentSession?.hello.processId ?? physicalProcessId
        return error
    }

    /// Whether a failure leaves a process nobody can describe.
    ///
    /// Narrower than it first was, because a review showed the old rule
    /// poisoned the everyday case of saving with no app running. The question
    /// is only ever "could this patch have taken effect", and there are two
    /// ways for the answer to be unknown: the request was sent and no answer
    /// came back, or the runtime answered at a stage where it cannot vouch for
    /// what happened.
    ///
    /// Everything the runtime does answer today means nothing took effect --
    /// a missing image was never opened, and `dlopen` unmaps an image it could
    /// not finish binding -- so those do not poison. The stages reserved for
    /// "cannot vouch" are REGISTER and VERIFY, which nothing emits yet; naming
    /// them here is what lets a future failure mode say so.
    /// UIKit entry points that have already run for every object that exists,
    /// and that nothing calls again just because a patch loaded.
    ///
    /// Replacing one is correct and invisible, which is the outcome this tool
    /// treats as worse than a refusal, so it is said out loud rather than
    /// left for the developer to discover by staring at an unchanged screen.
    /// It is a caveat and not a rejection, because the reload itself stands:
    /// any object created from now on gets the new body. There is no option
    /// that makes it visible sooner --- one was built and removed; see
    /// `Ember.RefreshOptions` --- so this note is the whole of the answer.
    ///
    /// Matched on the replacement target --- the name with its argument labels
    /// --- and only for a member of some type. A method of one's own called
    /// `viewDidLoad` earns the same note; the cost of that is a line of output,
    /// and what the line says of it is still true, since UIKit is not going to
    /// call it again either. If the developer's own code calls it, they can see
    /// that from the same screen they are reading.
    ///
    /// Every entry carries its parentheses, and that is what keeps a *property*
    /// named `viewDidLoad` out: a property's replacement target is the bare
    /// name, so it cannot match. Pinned by
    /// `everyOneShotTargetIsSpelledAsAFunction`, because the protection is in
    /// the spelling rather than in a check anybody can see. `contextPath` does
    /// the rest: a top-level function has no type for the advice to name.
    ///
    /// The scope is not decoration. A view or a scene can be made again inside
    /// the live process, which holds the patch, so the next one runs the new
    /// body. An application delegate cannot: there is one per process, and a
    /// relaunched process starts from the built binary with nothing loaded ---
    /// so for those the honest advice is the opposite one.
    static let oneShotLifecycleTargets: [String: OneShotScope] = [
        "loadView()": .instance,
        "viewDidLoad()": .instance,
        "awakeFromNib()": .instance,
        "scene(_:willConnectTo:options:)": .instance,
        "application(_:didFinishLaunchingWithOptions:)": .process,
        "applicationDidFinishLaunching(_:)": .process,
    ]

    private static func oneShotLifecycleMethods(among declarations: [PatchableDeclaration]) -> [OneShotNote] {
        declarations.compactMap { declaration in
            guard declaration.contextPath != nil,
                  let scope = oneShotLifecycleTargets[declaration.replacementTarget]
            else { return nil }
            return OneShotNote(name: declaration.displayName, scope: scope)
        }
    }

    static func cannotDescribeProcess(after error: any Error) -> Bool {
        switch error {
        case IPCServer.IPCError.timedOut, IPCServer.IPCError.disconnected:
            true            // sent; the outcome is unknown
        case IPCServer.IPCError.notConnected,
             IPCServer.IPCError.sendFailed:
            false           // never left the daemon
        case IPCServer.IPCError.versionMismatch:
            // The two sides cannot read each other, so the request was not
            // understood and nothing was applied. Saying "relaunch the app"
            // here would be both wrong and unhelpful: what is needed is a
            // matching runtime.
            false
        case let failure as EmberError:
            // The physical bridge has already classified its failures. A
            // rebuild/configuration response proves the runtime rejected the
            // request; `.restart` is reserved for a timeout or another result
            // whose effect on the process is unknown.
            failure.recovery == .restart
        default:
            true            // an unrecognised failure around the send
        }
    }

    /// Keeps the bridge's structured recovery advice intact. In particular a
    /// protocol mismatch needs a rebuild and a signing failure needs project
    /// configuration; wrapping every physical-device failure as `.restart`
    /// sent the developer toward an action that could not fix either one.
    static func loadFailure(from error: any Error, subject: String) -> EmberError {
        if let failure = error as? EmberError { return failure }
        let recovery: EmberError.Recovery
        if case IPCServer.IPCError.versionMismatch = error { recovery = .rebuild }
        else { recovery = .restart }
        return EmberError(stage: .load, subject: subject,
                           reason: "\(error)", recovery: recovery)
    }

    private static func cannotDescribeProcess(afterRuntimeStage stage: Stage) -> Bool {
        stage == .register || stage == .verify
    }

    public func handle(change url: URL) async -> Outcome {
        await handle(changes: [url])
    }

    private func targetKey(_ resolution: ModuleResolver.Resolution) -> String {
        resolution.module + "\u{0}" + (resolution.manifest?.standardizedFileURL.path ?? "")
    }

    /// Applies one complete file-watcher batch as one dynamic image.
    ///
    /// Classification and generation finish for every contributing file
    /// before anything reaches the application. Baselines and session memory
    /// advance only after that single image is confirmed loaded, so there is
    /// no state in which the process represents only a successful prefix of a
    /// multi-file save.
    public func handle(changes input: [URL]) async -> Outcome {
        let inputURLs = Set(input.map(\.standardizedFileURL))
            .sorted { $0.path < $1.path }
        guard !inputURLs.isEmpty else { return .ignored }

        let inputSet = Set(inputURLs)
        let directlyTouchedTargets = Set(inputURLs.map {
            targetKey(resolver.resolve($0))
        })
        for url in inputURLs {
            let target = targetKey(resolver.resolve(url))
            deferredTargets[target, default: DeferredTarget()].urls.insert(url)
        }

        // A safe event for a blocker also wakes the target that was waiting on
        // it, even though that URL belongs to another compiler context.
        var affectedTargets = directlyTouchedTargets
        for (target, deferred) in deferredTargets
            where !deferred.blockers.isDisjoint(with: inputSet) {
            affectedTargets.insert(target)
        }
        let urls = Array(affectedTargets.flatMap {
            deferredTargets[$0]?.urls ?? []
        }).sorted { $0.path < $1.path }

        let next = generation + 1
        let timeline = StageTimeline(generation: next)
        var currentIndexes: [URL: FileIndex] = [:]
        var currentChanges: [PreparedChange] = []
        var noChangeURLs: Set<URL> = []
        var refusal: EmberError?
        var refusedURLs: Set<URL> = []
        var safelyObservedURLs: Set<URL> = []

        // One classification timing for the atomic unit. Indexing is the bulk
        // of this stage, and splitting it into one row per file would make the
        // generation summary stop adding up to the batch the user saved.
        timeline.measure(.classify) {
            for url in urls {
                let baseline = baselines[url] ?? ""
                guard let current = try? String(contentsOf: url, encoding: .utf8) else {
                    refusedURLs.insert(url)
                    if refusal == nil {
                        refusal = EmberError(
                            stage: .watch, subject: url.lastPathComponent,
                            reason: "the changed source could not be read, so the complete save batch is unavailable",
                            recovery: .editAndRetry)
                    }
                    continue
                }
                let currentIndex = DeclarationIndexer.index(source: current)
                let baselineIndex = baselineIndexes[url]
                    ?? DeclarationIndexer.index(source: baseline)
                baselineIndexes[url] = baselineIndex
                currentIndexes[url] = currentIndex
                let memory = memories[url] ?? SessionMemory()

                switch ChangeClassifier.classifyForBatch(
                    before: baselineIndex, after: currentIndex,
                    memory: memory) {
                case .noChange:
                    noChangeURLs.insert(url)
                    safelyObservedURLs.insert(url)
                    continue
                case .rebuildRequired(let reason):
                    refusedURLs.insert(url)
                    if refusal == nil {
                        refusal = EmberError(stage: .classify, subject: url.lastPathComponent,
                                             reason: reason, recovery: .rebuild)
                    }
                case .hotPatch(let plan):
                    let updatesLoadedContribution = memory.carried.contains { identity in
                        baselineIndex.patchable[identity]?.body
                            != currentIndex.patchable[identity]?.body
                    }
                    let change = PreparedChange(
                        url: url, current: current, index: currentIndex, plan: plan,
                        resolution: resolver.resolve(url),
                        updatesLoadedContribution: updatesLoadedContribution)
                    currentChanges.append(change)
                    safelyObservedURLs.insert(url)
                }
            }
        }

        var newlyUnblockedTargets: Set<String> = []
        for target in Array(deferredTargets.keys) {
            guard var deferred = deferredTargets[target] else { continue }
            let wasBlocked = !deferred.blockers.isEmpty
            deferred.blockers.subtract(safelyObservedURLs)
            if wasBlocked && deferred.blockers.isEmpty {
                newlyUnblockedTargets.insert(target)
            }
            deferredTargets[target] = deferred
        }

        if let refusal {
            for target in affectedTargets {
                deferredTargets[target]?.blockers.formUnion(refusedURLs)
            }
            return .rejected(refusal)
        }

        // A reverted URL no longer differs from the process and therefore no
        // longer belongs to any deferred unit.
        for target in affectedTargets {
            guard var deferred = deferredTargets[target] else { continue }
            deferred.urls.subtract(noChangeURLs)
            if deferred.urls.isEmpty {
                deferredTargets.removeValue(forKey: target)
            } else {
                deferredTargets[target] = deferred
            }
        }

        var candidateTargets = directlyTouchedTargets.union(newlyUnblockedTargets)
        candidateTargets = Set(candidateTargets.filter { deferredTargets[$0] != nil })
        guard !candidateTargets.isEmpty else { return .ignored }

        let unresolvedBlockers = candidateTargets.reduce(into: Set<URL>()) {
            blockers, target in
            blockers.formUnion(deferredTargets[target]?.blockers ?? [])
        }
        if !unresolvedBlockers.isEmpty {
            // Every target participating in this poll waits on the same union;
            // this preserves the poll as one unit without retaining snapshots.
            for target in candidateTargets {
                deferredTargets[target]?.blockers.formUnion(unresolvedBlockers)
            }
            let names = unresolvedBlockers.map(\.lastPathComponent).sorted()
                .joined(separator: ", ")
            return .rejected(EmberError(
                stage: .classify, subject: "\(urls.count) source files",
                reason: "a deferred atomic reload is still waiting for a safe event from: \(names)",
                recovery: .editAndRetry))
        }

        let currentByURL = Dictionary(
            uniqueKeysWithValues: currentChanges.map { ($0.url, $0) })
        let effectiveChanges = candidateTargets.flatMap { target in
            (deferredTargets[target]?.urls ?? []).compactMap { currentByURL[$0] }
        }

        // An addition with no changed caller is deliberately left pending. It
        // joins a later atomic patch when another file begins to use it, but a
        // carried-only image would register no replacement and change nothing.
        let observable = effectiveChanges.filter(\.requiresImage)
            .sorted { $0.url.path < $1.url.path }
        guard !observable.isEmpty else { return .ignored }

        let targets = Set(observable.map { targetKey($0.resolution) })
        let initialSubject = observable.count == 1
            ? observable[0].url.lastPathComponent
            : "\(observable.count) source files"
        guard targets.count == 1, let resolution = observable.first?.resolution else {
            let details = observable.map { change in
                let package = change.resolution.manifest.map { " (\($0.path))" } ?? ""
                return "  \(change.url.lastPathComponent): \(change.resolution.module)\(package)"
            }.joined(separator: "\n")
            return .rejected(EmberError(
                stage: .classify, subject: initialSubject,
                reason: """
                    one atomic image cannot preserve different module or Swift \
                    language-mode contexts:

                    \(details)

                    No part of this save was loaded. Rebuild to apply the \
                    cross-module change.
                    """,
                recovery: .rebuild))
        }
        let module = resolution.module
        let selectedTarget = targetKey(resolution)

        let prepared = (deferredTargets[selectedTarget]?.urls ?? [])
            .compactMap { currentByURL[$0] }
            .sorted { $0.url.path < $1.url.path }
        let subject = prepared.count == 1
            ? prepared[0].url.lastPathComponent
            : "\(prepared.count) source files"
        let preparedURLs = Set(prepared.map(\.url))
        var contributions = prepared.map {
            PatchContribution(url: $0.url, index: $0.index, plan: $0.plan)
        }

        // A declaration added by an earlier patch exists only in that dylib.
        // Re-emit the module's complete session contribution so a replacement
        // in another source file can keep calling it in every later generation.
        for url in memories.keys.sorted(by: { $0.path < $1.path }) where !preparedURLs.contains(url) {
            let rememberedResolution = resolver.resolve(url)
            guard targetKey(rememberedResolution) == targetKey(resolution),
                  let baseline = baselines[url] else { continue }
            let index = baselineIndexes[url] ?? DeclarationIndexer.index(source: baseline)
            baselineIndexes[url] = index
            guard let memory = memories[url] else { continue }
            let carried = memory.carried.compactMap { index.patchable[$0] }
                .sorted { $0.identity < $1.identity }
            let replacements = memory.replaced.subtracting(memory.carried)
                .compactMap { index.patchable[$0] }
                .sorted { $0.identity < $1.identity }
            guard !carried.isEmpty || !replacements.isEmpty else { continue }
            contributions.append(PatchContribution(
                url: url, index: index,
                plan: PatchPlan(replacements: replacements, carried: carried)))
        }

        let declarations = contributions.flatMap(\.plan.replacements)
        let carried = contributions.flatMap(\.plan.carried)
        var effectiveIndexes = currentIndexes
        for change in prepared { effectiveIndexes[change.url] = change.index }

        // Syntax can identify the boundary call but cannot reproduce overload
        // resolution for a method declared in another source file of the app
        // module. Include the new indexes for every file in this batch: using
        // their old baselines here would allow the first half of an unsafe
        // multi-file edit into the process.
        for contribution in contributions
            where contribution.plan.replacements.contains(where: \.requiresAnyViewBoundaryValidation) {
            if let conflict = emberBoundaryNameConflict(
                excluding: contribution.url, updatedIndexes: effectiveIndexes) {
                return .rejected(EmberError(
                    stage: .classify, subject: contribution.url.lastPathComponent,
                    reason: """
                        \(conflict.lastPathComponent) declares `emberable`, which is \
                        reserved while a SwiftUI body uses the ember boundary. A \
                        shadowing overload can remove `AnyView`; rename it and rebuild.
                        """,
                    recovery: .rebuild))
            }
        }

        // After every source-only filter. A poisoned session should not hide a
        // useful classification error, but no compile or transfer may begin
        // while the process is undescribable.
        if let physicalDevice, let processId = physicalDevice.connectedProcess() {
            sessionDidConnect(processId: processId)
            physicalProcessId = processId
        }
        if let uncertain {
            // URLs stay deferred. A later event after relaunch re-reads their
            // current contents instead of reviving a stored snapshot.
            return .sessionUncertain(uncertain)
        }

        guard inventory.isPatchable(module) else {
            return .rejected(EmberError(
                stage: .classify, subject: subject,
                reason: """
                    \(module) exports no dynamic replacement keys, so nothing in it \
                    can be replaced.

                    Xcode does not pass OTHER_SWIFT_FLAGS into Swift package targets, \
                    so a package needs the setting in its own manifest:

                        .target(name: "\(module)", swiftSettings: [
                            .unsafeFlags(["-Xfrontend", "-enable-implicit-dynamic"],
                                         .when(configuration: .debug))
                        ])

                    Patchable modules in this build: \(inventory.patchableModules.joined(separator: ", "))
                    """,
                recovery: .rebuild))
        }

        var flags = context.extraCompilerFlags
        if let manifest = resolution.manifest {
            switch PackageLanguageMode.read(from: manifest) {
            case .mode(let mode):
                flags = Self.replacingLanguageMode(in: flags, with: mode)
            case .unknown(let reason):
                return .rejected(EmberError(
                    stage: .classify, subject: subject,
                    reason: """
                        \(module) is a local package and \(reason), so the language mode \
                        this patch would be compiled under is a guess.

                        A body type-checked under the wrong mode loses the isolation and \
                        sendability rules the package was written with, and the result \
                        compiles.
                        """,
                    recovery: .configure))
            }
        }

        do {
            let files = contributions.map { contribution in
                PatchFilePlan(
                    plan: contribution.plan, imports: contribution.index.imports,
                    privateImportOf: contribution.index.declaresFileLocal
                        ? contribution.url.lastPathComponent : nil)
            }
            let sources = try timeline.measure(.generate) {
                try ReplacementGenerator.generateFiles(
                    module: module, generation: next, files: files)
            }
            let artifact = try compiler.compile(sources: sources, generation: next,
                                                flags: flags, timeline: timeline)

            let delivered = try timeline.measure(.transfer) {
                if let deliverOverride { return try deliverOverride(artifact.imageURL) }
                if let physicalDevice { return try physicalDevice.deliver(artifact.imageURL) }
                guard let simulatorContainer else {
                    throw EmberError(stage: .transfer, subject: artifact.imageURL.lastPathComponent,
                                      reason: "no app-container transport was configured",
                                      recovery: .configure)
                }
                return try simulatorContainer.deliver(artifact.imageURL)
            }

            // Carried declarations replace nothing and are absent from the
            // runtime's section count. Every actual replacement from every
            // contributing file must be present before the batch can stand.
            let expected = declarations.reduce(0) { $0 + $1.replacementCount }
            var verified = false
            var counted: Int?
            var refreshed: String?
            let start = DispatchTime.now().uptimeNanoseconds
            let request = LoadPatchRequest(generation: next, path: delivered.path,
                                           buildIdentity: context.identity,
                                           buildUUIDs: buildUUIDs,
                                           declarations: declarations.map(\.displayName))
            let result: LoadPatchResult
            do {
                if let physicalDevice {
                    let reply = try await physicalDevice.requestLoad(request)
                    sessionDidConnect(processId: reply.processId)
                    physicalProcessId = reply.processId
                    result = reply.result
                } else {
                    result = try await server.request(type: "loadPatch", payload: request,
                                                      expecting: LoadPatchResult.self)
                }
            } catch {
                timeline.record(.load, since: start, success: false)
                let failure = Self.loadFailure(from: error, subject: subject)
                throw Self.cannotDescribeProcess(after: error) ? poison(failure) : failure
            }

            switch result {
            case .loaded(let echoed, _, let registered, let refresh):
                timeline.record(.load, since: start, success: true)
                guard echoed == next else {
                    throw poison(EmberError(
                        stage: .register, subject: subject,
                        reason: "asked the app to load g\(next) and it answered about g\(echoed)",
                        recovery: .restart))
                }
                if let registered, registered < expected {
                    throw poison(EmberError(
                        stage: .register, subject: subject,
                        reason: registered == 0
                            ? "the patch loaded and registered no replacements at all"
                            : "the patch registered \(registered) replacements; \(expected) were generated",
                        recovery: .restart))
                }
                verified = registered == expected
                counted = registered
                refreshed = refresh
            case .rejected(let reason):
                timeline.record(.load, since: start, success: false)
                throw EmberError(stage: .load, subject: subject,
                                  reason: reason, recovery: .rebuild)
            case .failed(let stage, let message):
                timeline.record(stage, since: start, success: false)
                let isUncertain = Self.cannotDescribeProcess(afterRuntimeStage: stage)
                let failure = EmberError(stage: stage, subject: subject, reason: message,
                                          recovery: isUncertain ? .restart : .editAndRetry)
                throw isUncertain ? poison(failure) : failure
            }

            // The only commit point. Nothing above changes the sources the
            // coordinator believes the process represents.
            generation = next
            for change in prepared {
                baselines[change.url] = change.current
                baselineIndexes[change.url] = change.index
                memories[change.url, default: SessionMemory()].remember(change.plan)
            }
            if var deferred = deferredTargets[selectedTarget] {
                deferred.urls.subtract(preparedURLs)
                if deferred.urls.isEmpty {
                    deferredTargets.removeValue(forKey: selectedTarget)
                } else {
                    deferredTargets[selectedTarget] = deferred
                }
            }
            return .applied(generation: next,
                            declarations: declarations.map(\.displayName),
                            carried: carried.map(\.displayName),
                            verified: verified,
                            registered: counted.map { ($0, expected) },
                            refreshed: refreshed,
                            oneShot: Self.oneShotLifecycleMethods(among: declarations),
                            timeline: timeline)
        } catch let error as EmberError {
            // The target's URLs remain deferred. The next event re-reads every
            // one, so a failed compile or load cannot commit a stale snapshot.
            return .rejected(error)
        } catch {
            return .rejected(EmberError(stage: .verify, subject: subject,
                                         reason: "unattributed failure: \(error)", recovery: .rebuild))
        }
    }

    /// A declaration in another file from the running build that can shadow
    /// the adapter's modifier. The edited file was already checked by its
    /// FileIndex. Excluded sources use their build-time text: ignored edits do
    /// not change the code already loaded in the process.
    private func emberBoundaryNameConflict(
        excluding edited: URL, updatedIndexes: [URL: FileIndex] = [:]
    ) -> URL? {
        let editedModule = resolver.resolve(edited).module
        let candidates = Set(baselines.keys).union(excludedSafetyBaselines.keys)
            .union(updatedIndexes.keys)
            .sorted { $0.path < $1.path }
        for candidate in candidates where candidate != edited {
            guard resolver.resolve(candidate).module == editedModule else { continue }
            if let index = updatedIndexes[candidate], index.declaresEmberable {
                return candidate
            }
            guard updatedIndexes[candidate] == nil,
                  let source = baselines[candidate] ?? excludedSafetyBaselines[candidate]
            else { continue }
            if DeclarationIndexer.index(source: source).declaresEmberable { return candidate }
        }
        return nil
    }
}

extension PatchCoordinator {
    /// Substitutes the `-swift-version` pair rather than appending one, because
    /// two of them is not a question the compiler answers predictably.
    static func replacingLanguageMode(in flags: [String], with mode: String) -> [String] {
        var result: [String] = []
        var index = flags.startIndex
        while index < flags.endIndex {
            if flags[index] == "-swift-version", flags.index(after: index) < flags.endIndex {
                index = flags.index(index, offsetBy: 2)
                continue
            }
            result.append(flags[index])
            index = flags.index(after: index)
        }
        return result + ["-swift-version", mode]
    }
}

/// Everything that depends on the app living in a simulator container.
/// Isolated here so that the rest of the daemon does not learn about `simctl`.
final class SimulatorContainer: @unchecked Sendable {
    let bundleIdentifier: String
    let deviceIdentifier: String?
    private let lock = NSLock()
    private var cached: URL?

    init(bundleIdentifier: String, deviceIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier
    }

    /// Forgets the cached path. Called when the app goes away, because a
    /// reinstall gives it a new container.
    func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Cached, because asking is expensive and the answer does not change
    /// while an install stays put.
    ///
    /// Measured at about 106 ms per call against 11 ms for the copy it exists
    /// to locate, so a third of the whole reload was spent launching `simctl`
    /// to be told the same path again.
    private func dataContainer() throws -> URL {
        if let cached = lock.withLock({ cached }) { return cached }

        let result = try Subprocess.run(
            "/usr/bin/xcrun",
            arguments: Self.containerArguments(
                bundleIdentifier: bundleIdentifier, deviceIdentifier: deviceIdentifier))
        let path = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw EmberError(stage: .transfer, subject: bundleIdentifier,
                              reason: "could not find the app container: \(path)",
                              recovery: .restart)
        }
        let url = URL(fileURLWithPath: path)
        lock.withLock { cached = url }
        return url
    }

    static func containerArguments(bundleIdentifier: String, deviceIdentifier: String?) -> [String] {
        ["simctl", "get_app_container", deviceIdentifier ?? "booted", bundleIdentifier, "data"]
    }

    /// The daemon publishes where to reach it into the app's own Documents
    /// directory. That is a path the runtime can always read, which a
    /// well-known host path is not.
    func writeSession(port: UInt16, token: String, buildIdentity: String,
                      buildUUIDs: [String]) throws {
        let documents = try dataContainer().appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let payload: [String: Any] = ["port": Int(port), "token": token,
                                      "buildIdentity": buildIdentity, "buildUUIDs": buildUUIDs]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        // Stable protocol identifier: existing runtimes still discover this
        // pre-Ember filename, so branding must not change it within protocol v6.
        try data.write(to: documents.appendingPathComponent("splice-session.json"))
    }

    func deliver(_ image: URL) throws -> URL {
        let inbox = try dataContainer()
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Patches", isDirectory: true)
        let destination = inbox.appendingPathComponent(image.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: image, to: destination)
        } catch {
            // FileManager throws plain NSErrors. Without translating them here
            // the coordinator's catch-all labelled a full disk or a vanished
            // container as a GENERATE failure and told the developer to fix
            // their source.
            throw EmberError(stage: .transfer, subject: image.lastPathComponent,
                              reason: "could not copy the patch into the app container: \(error.localizedDescription)",
                              recovery: .restart)
        }
        return destination
    }
}

/// A replaced declaration that has already run, and how far out of reach the
/// new body is.
public struct OneShotNote: Sendable, Equatable {
    public let name: String
    public let scope: OneShotScope

    public init(name: String, scope: OneShotScope) {
        self.name = name
        self.scope = scope
    }
}

public enum OneShotScope: Sendable, Equatable {
    /// Another one can be made inside this process, and it will run the new
    /// body: a view controller, a view, a scene.
    case instance
    /// There is one per process. A relaunch is the only way to make another,
    /// and a relaunched process starts from the built binary with no patch in
    /// it, so the new body needs a build rather than a restart.
    case process
}
