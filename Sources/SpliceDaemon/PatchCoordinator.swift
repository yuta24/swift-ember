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
    private var baselines: [URL: String] = [:]
    /// The baseline's parsed form, kept because it only changes when a patch
    /// lands. Re-parsing it on every save doubled the cost of classification,
    /// which is the one stage that grows with the size of the file being
    /// edited.
    private var baselineIndexes: [URL: FileIndex] = [:]
    private var generation: UInt64 = 0

    public init(context: BuildContext, server: IPCServer, workDirectory: URL) {
        self.context = context
        self.server = server
        self.compiler = PatchCompiler(context: context, workDirectory: workDirectory)
        self.container = SimulatorContainer(bundleIdentifier: context.bundleIdentifier)
    }

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
        case applied(generation: UInt64, declarations: [String], timeline: StageTimeline)
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
            return (currentIndex, ChangeClassifier.classify(before: baselineIndex, after: currentIndex))
        }

        let declarations: [PatchableDeclaration]
        switch classification {
        case .noChange:
            return .ignored
        case .rebuildRequired(let reason):
            return .rejected(SpliceError(stage: .classify, subject: url.lastPathComponent,
                                         reason: reason, recovery: .rebuild))
        case .hotPatch(let changed):
            declarations = changed
        }

        do {
            let imports = currentIndex.imports
            let source = try timeline.measure(.generate) {
                try ReplacementGenerator.generate(module: context.moduleName,
                                                  generation: next, declarations: declarations,
                                                  imports: imports)
            }

            let artifact = try compiler.compile(source: source, generation: next, timeline: timeline)

            let delivered = try timeline.measure(.transfer) {
                try container.deliver(artifact.imageURL)
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
                throw SpliceError(stage: .load, subject: url.lastPathComponent,
                                  reason: "\(error)", recovery: .restart)
            }

            switch result {
            case .loaded:
                timeline.record(.load, since: start, success: true)
            case .rejected(let reason):
                timeline.record(.load, since: start, success: false)
                throw SpliceError(stage: .load, subject: url.lastPathComponent,
                                  reason: reason, recovery: .rebuild)
            case .failed(let stage, let message):
                timeline.record(stage, since: start, success: false)
                // A failure inside dlopen may leave the process half-patched,
                // and section 17 says not to claim otherwise.
                throw SpliceError(stage: stage, subject: url.lastPathComponent,
                                  reason: message, recovery: .restart)
            }

            generation = next
            baselines[url] = current
            baselineIndexes[url] = currentIndex
            return .applied(generation: next, declarations: declarations.map(\.displayName), timeline: timeline)
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
