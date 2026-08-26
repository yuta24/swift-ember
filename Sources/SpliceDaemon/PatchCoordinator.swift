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
                inventory: ModuleInventory? = nil,
                buildUUIDs: [String]? = nil) {
        self.context = context
        self.server = server
        self.compiler = PatchCompiler(context: context, workDirectory: workDirectory)
        self.container = SimulatorContainer(bundleIdentifier: context.bundleIdentifier)
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
                                   buildIdentity: context.identity, buildUUIDs: buildUUIDs)
    }

    public enum Outcome: Sendable {
        case ignored
        case rejected(SpliceError)
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
    /// UIKit entry points that have already run for every object that exists,
    /// and that nothing calls again just because a patch loaded.
    ///
    /// Replacing one is correct and invisible, which is the outcome this tool
    /// treats as worse than a refusal, so it is said out loud rather than
    /// left for the developer to discover by staring at an unchanged screen.
    /// It is a caveat and not a rejection, because the reload itself stands:
    /// any object created from now on gets the new body. There is no option
    /// that makes it visible sooner --- one was built and removed; see
    /// `Splice.RefreshOptions` --- so this note is the whole of the answer.
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

    private static func cannotDescribeProcess(after error: any Error) -> Bool {
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

        // One measurement: indexing is the bulk of classification, and two
        // rows in the summary read as two stages.
        let (currentIndex, classification) = timeline.measure(.classify) {
            let currentIndex = DeclarationIndexer.index(source: current)
            let baselineIndex = baselineIndexes[url]
                ?? DeclarationIndexer.index(source: baseline)
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
        let resolution = resolver.resolve(url)
        let module = resolution.module
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

        // A local package's target need not share the application's language
        // mode, and the build settings do not report one for it. Compiling a
        // Swift 6 package's file under the app's Swift 5 was measured accepting
        // a body the project's own compiler rejects as a data race.
        var flags = context.extraCompilerFlags
        if let manifest = resolution.manifest {
            switch PackageLanguageMode.read(from: manifest) {
            case .mode(let mode):
                flags = Self.replacingLanguageMode(in: flags, with: mode)
            case .unknown(let reason):
                return .rejected(SpliceError(
                    stage: .classify, subject: url.lastPathComponent,
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
            let imports = currentIndex.imports
            let source = try timeline.measure(.generate) {
                try ReplacementGenerator.generate(
                    module: module, generation: next, plan: plan, imports: imports,
                    // Only when the file has private code to reach. A project
                    // without -enable-private-imports then keeps working for
                    // everything else, instead of failing on every save.
                    privateImportOf: currentIndex.declaresFileLocal ? url.lastPathComponent : nil)
            }

            let artifact = try compiler.compile(source: source, generation: next,
                                                flags: flags, timeline: timeline)

            let delivered = try timeline.measure(.transfer) {
                try deliverOverride?(artifact.imageURL) ?? container.deliver(artifact.imageURL)
            }

            // What the loaded image should say it replaced. Declarations, not
            // their count: a computed property with a getter and a setter is
            // one declaration and two records.
            //
            // Carried declarations are deliberately absent from this sum. They
            // replace nothing, and the runtime does not count them -- see
            // `RegisteredReplacements`, which distinguishes the two by how
            // many selectors reach an implementation. An earlier version
            // allowed for them with a range instead, and the range cancelled
            // the check: an `@objcMembers` class where the edit also extracted
            // a helper produced a patch whose replacement was missing
            // entirely, whose carried helper made up the difference, and which
            // was therefore reported as a verified reload. Measured, and
            // cumulative --- `SessionMemory` re-emits carried declarations, so
            // the slack grew with every save for the rest of the session.
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
                result = try await server.request(type: "loadPatch", payload: request,
                                                  expecting: LoadPatchResult.self)
            } catch {
                timeline.record(.load, since: start, success: false)
                // A version mismatch is not fixed by restarting: the runtime is
                // compiled into the application, so the app has to be built
                // again. Reported as `.restart`, it sent people round a loop
                // that could not end.
                let recovery: SpliceError.Recovery
                if case IPCServer.IPCError.versionMismatch = error { recovery = .rebuild }
                else { recovery = .restart }
                let failure = SpliceError(stage: .load, subject: url.lastPathComponent,
                                          reason: "\(error)", recovery: recovery)
                // No answer is not the same as no load: a request that was
                // sent may have been carried out and its reply lost. One that
                // never left the daemon, because nothing was connected, leaves
                // the app exactly where it was -- and that is the ordinary case
                // of saving a file before launching the app.
                throw Self.cannotDescribeProcess(after: error) ? poison(failure) : failure
            }

            switch result {
            case .loaded(let echoed, _, let registered, let refresh):
                timeline.record(.load, since: start, success: true)
                // The generation came back for a reason. A runtime answering
                // about a different one is not a runtime whose answer about
                // this one means anything -- and it was being discarded, so a
                // reply naming g999999 was reported as a successful reload of
                // g1.
                guard echoed == next else {
                    throw poison(SpliceError(
                        stage: .register, subject: url.lastPathComponent,
                        reason: "asked the app to load g\(next) and it answered about g\(echoed)",
                        recovery: .restart))
                }
                // FR-13. `dlopen` returning a handle says the image mapped, not
                // that the Swift runtime bound anything in it. The count comes
                // from the image's own replacement section -- the same one the
                // runtime reads -- so a patch that loaded and replaced nothing
                // is a failure with a stage of its own rather than a reload
                // nobody can tell from a real one.
                if let registered, registered < expected {
                    throw poison(SpliceError(
                        stage: .register, subject: url.lastPathComponent,
                        reason: registered == 0
                            ? "the patch loaded and registered no replacements at all"
                            : "the patch registered \(registered) replacements; \(expected) were generated",
                        recovery: .restart))
                }
                // Fewer than expected is the failure FR-13 names: the patch did
                // less than it said. More is not a failure --- a patch cannot
                // register a replacement it does not contain, so a count above
                // the expected one says the reader misread the image rather
                // than that the process is wrong, and ending a session every
                // time a toolchain moved a field would be worse than saying so.
                // It is reported as unverified instead.
                verified = registered == expected
                counted = registered
                refreshed = refresh
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
                            carried: plan.carried.map(\.displayName),
                            verified: verified,
                            registered: counted.map { ($0, expected) },
                            refreshed: refreshed,
                            oneShot: Self.oneShotLifecycleMethods(among: declarations),
                            timeline: timeline)
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
    func writeSession(port: UInt16, token: String, buildIdentity: String,
                      buildUUIDs: [String]) throws {
        let documents = try dataContainer().appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let payload: [String: Any] = ["port": Int(port), "token": token,
                                      "buildIdentity": buildIdentity, "buildUUIDs": buildUUIDs]
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
