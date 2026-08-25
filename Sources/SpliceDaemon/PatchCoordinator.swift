import Foundation
import SpliceCore
import SpliceGen

/// Drives one save through the pipeline: classify, generate, compile, deliver,
/// load, report.
///
/// Everything policy-shaped lives here rather than in the runtime, per
/// DESIGN.md section 4.3. The runtime's only decision is whether `dlopen`
/// worked.
public actor PatchCoordinator {
    private let context: BuildContext
    private let server: IPCServer
    private let compiler: PatchCompiler
    private let container: SimulatorContainer
    private let resolver: ModuleResolver
    /// Read once per session from the running binary. A rebuild changes it,
    /// and a rebuild means a relaunch, which is a new session.
    private lazy var inventory = inventoryOverride
        ?? ModuleInventory.read(from: context.linkTarget)
    private let inventoryOverride: ModuleInventory?
    /// Set when a patch may have been partly applied and cleared only by a
    /// fresh process.
    ///
    /// DESIGN.md section 17: a load or registration failure may leave the
    /// process in an uncertain state, and the session should say "restart
    /// recommended" unless recovery is proven. Until this existed the daemon
    /// printed the failure and went on patching a process whose contents it
    /// could no longer describe -- reporting later reloads as successful on
    /// top of a state nobody could vouch for.
    private var uncertain: SpliceError?
    /// The process the flag is about. Clearing needs a different one.
    private var uncertainProcess: Int32?

    private var baselines: [URL: String] = [:]
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
                inventory: ModuleInventory? = nil) {
        self.context = context
        self.server = server
        self.compiler = PatchCompiler(context: context, workDirectory: workDirectory)
        self.container = SimulatorContainer(bundleIdentifier: context.bundleIdentifier)
        self.resolver = ModuleResolver(appModule: context.moduleName)
        self.deliverOverride = deliver
        self.inventoryOverride = inventory
    }

    private let deliverOverride: (@Sendable (URL) throws -> URL)?

    /// Snapshots the sources as they were when the running binary was built.
    /// Everything afterwards is diffed against this, and the baseline advances
    /// only when a patch actually lands, so a rejected edit stays visible on
    /// the next save instead of being silently absorbed.
    public func primeBaselines(from roots: [URL]) {
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // Text only. Parsing every file at startup would cost a large
                // project seconds before the first edit, and most files are
                // never touched in a session.
                baselines[url.standardizedFileURL] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
        container.invalidate()
        try container.writeSession(port: server.port, token: server.token,
                                   buildIdentity: context.identity)
    }

    public enum Outcome: Sendable {
        case ignored
        case rejected(SpliceError)
        case applied(generation: UInt64, declarations: [String], carried: [String],
                     timeline: StageTimeline)
        /// Refused without being examined, because the running process can no
        /// longer be described. Carries the failure that caused it.
        case sessionUncertain(SpliceError)
    }

    public var isUncertain: Bool { uncertain != nil }

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
    private func poison(_ error: SpliceError) -> SpliceError {
        uncertain = error
        uncertainProcess = server.currentSession?.hello.processId
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
    private static func cannotDescribeProcess(after error: any Error) -> Bool {
        switch error {
        case IPCServer.IPCError.timedOut, IPCServer.IPCError.disconnected:
            true            // sent; the outcome is unknown
        case IPCServer.IPCError.notConnected:
            false           // never left the daemon
        default:
            true            // an unrecognised failure around the send
        }
    }

    private static func cannotDescribeProcess(afterRuntimeStage stage: Stage) -> Bool {
        stage == .register || stage == .verify
    }

    public func handle(change url: URL) async -> Outcome {
        let url = url.standardizedFileURL
        let baseline = baselines[url] ?? ""
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return .ignored }

        let next = generation + 1
        let timeline = StageTimeline(generation: next)

        let policy = ClassifierPolicy.fromEnvironment
        // One measurement: indexing is the bulk of classification, and two
        // rows in the summary read as two stages.
        let (currentIndex, classification) = timeline.measure(.classify) {
            let currentIndex = DeclarationIndexer.index(source: current, policy: policy)
            let baselineIndex = baselineIndexes[url]
                ?? DeclarationIndexer.index(source: baseline, policy: policy)
            baselineIndexes[url] = baselineIndex
            return (currentIndex, ChangeClassifier.classify(before: baselineIndex, after: currentIndex,
                                                            memory: memories[url] ?? SessionMemory()))
        }

        let plan: PatchPlan
        switch classification {
        case .noChange:
            return .ignored
        case .rebuildRequired(let reason):
            return .rejected(SpliceError(stage: .classify, subject: url.lastPathComponent,
                                         reason: reason, recovery: .rebuild))
        case .hotPatch(let planned):
            plan = planned
        }
        let declarations = plan.replacements

        // After the filters. Checked first, a poisoned session printed the
        // whole paragraph for every touched file -- and a build or a checkout
        // touches many, none of which would have been patched anyway.
        if let uncertain { return .sessionUncertain(uncertain) }

        // Which module owns this file decides what the patch imports and what
        // it is compiled against. A module that exports no replacement keys
        // cannot be patched at all, and saying so here is the difference
        // between a refusal and an edit that silently does nothing -- which is
        // what editing a Swift package used to do.
        let module = resolver.module(for: url)
        guard inventory.isPatchable(module) else {
            return .rejected(SpliceError(
                stage: .classify, subject: url.lastPathComponent,
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

        do {
            let imports = currentIndex.imports
            let source = try timeline.measure(.generate) {
                try ReplacementGenerator.generate(
                    module: module, generation: next, plan: plan, imports: imports,
                    // Only when the file has private code to reach. A project
                    // without -enable-private-imports then keeps working for
                    // everything else, instead of failing on every save.
                    privateImportOf: currentIndex.declaresFileLocal ? url.lastPathComponent : nil)
            }

            let artifact = try compiler.compile(source: source, generation: next, timeline: timeline)

            let delivered = try timeline.measure(.transfer) {
                try deliverOverride?(artifact.imageURL) ?? container.deliver(artifact.imageURL)
            }

            let start = DispatchTime.now().uptimeNanoseconds
            let request = LoadPatchRequest(generation: next, path: delivered.path,
                                           buildIdentity: context.identity,
                                           declarations: declarations.map(\.displayName))
            let result: LoadPatchResult
            do {
                result = try await server.request(type: "loadPatch", payload: request,
                                                  expecting: LoadPatchResult.self)
            } catch {
                timeline.record(.load, since: start, success: false)
                let failure = SpliceError(stage: .load, subject: url.lastPathComponent,
                                          reason: "\(error)", recovery: .restart)
                // No answer is not the same as no load: a request that was
                // sent may have been carried out and its reply lost. One that
                // never left the daemon, because nothing was connected, leaves
                // the app exactly where it was -- and that is the ordinary case
                // of saving a file before launching the app.
                throw Self.cannotDescribeProcess(after: error) ? poison(failure) : failure
            }

            switch result {
            case .loaded:
                timeline.record(.load, since: start, success: true)
            case .rejected(let reason):
                timeline.record(.load, since: start, success: false)
                // The runtime declined before loading anything, so the process
                // is exactly where it was. This one does not poison.
                throw SpliceError(stage: .load, subject: url.lastPathComponent,
                                  reason: reason, recovery: .rebuild)
            case .failed(let stage, let message):
                timeline.record(stage, since: start, success: false)
                let uncertain = Self.cannotDescribeProcess(afterRuntimeStage: stage)
                let failure = SpliceError(stage: stage, subject: url.lastPathComponent,
                                          reason: message,
                                          recovery: uncertain ? .restart : .editAndRetry)
                throw uncertain ? poison(failure) : failure
            }

            generation = next
            baselines[url] = current
            baselineIndexes[url] = currentIndex
            memories[url, default: SessionMemory()].remember(plan)
            return .applied(generation: next, declarations: declarations.map(\.displayName),
                            carried: plan.carried.map(\.displayName), timeline: timeline)
        } catch let error as SpliceError {
            return .rejected(error)
        } catch {
            // Anything reaching here failed to name its own stage, so do not
            // invent one. Every deliberate failure above throws a SpliceError.
            return .rejected(SpliceError(stage: .verify, subject: url.lastPathComponent,
                                         reason: "unattributed failure: \(error)", recovery: .rebuild))
        }
    }
}

/// Everything that depends on the app living in a simulator container.
/// Isolated here so that the rest of the daemon does not learn about `simctl`.
final class SimulatorContainer: @unchecked Sendable {
    let bundleIdentifier: String
    private let lock = NSLock()
    private var cached: URL?

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
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

        let result = try Subprocess.run("/usr/bin/xcrun",
                                        arguments: ["simctl", "get_app_container", "booted", bundleIdentifier, "data"])
        let path = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw SpliceError(stage: .transfer, subject: bundleIdentifier,
                              reason: "could not find the app container: \(path)",
                              recovery: .restart)
        }
        let url = URL(fileURLWithPath: path)
        lock.withLock { cached = url }
        return url
    }

    /// The daemon publishes where to reach it into the app's own Documents
    /// directory. That is a path the runtime can always read, which a
    /// well-known host path is not.
    func writeSession(port: UInt16, token: String, buildIdentity: String) throws {
        let documents = try dataContainer().appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let payload: [String: Any] = ["port": Int(port), "token": token, "buildIdentity": buildIdentity]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
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
            throw SpliceError(stage: .transfer, subject: image.lastPathComponent,
                              reason: "could not copy the patch into the app container: \(error.localizedDescription)",
                              recovery: .restart)
        }
        return destination
    }
}
