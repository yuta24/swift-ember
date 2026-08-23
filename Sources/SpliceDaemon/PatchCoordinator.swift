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
                baselines[url.standardizedFileURL] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    public func announceSession() throws {
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

        let classification = timeline.measure(.classify) {
            ChangeClassifier.classify(baseline: baseline, current: current)
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
            let source = try timeline.measure(.generate) {
                try ReplacementGenerator.generate(module: context.moduleName,
                                                  generation: next, declarations: declarations)
            }

            let artifact = try compiler.compile(source: source, generation: next, timeline: timeline)

            let delivered = try timeline.measure(.transfer) {
                try container.deliver(artifact.imageURL)
            }

            let start = DispatchTime.now().uptimeNanoseconds
            let request = LoadPatchRequest(generation: next, path: delivered.path,
                                           buildIdentity: context.identity,
                                           declarations: declarations.map(\.identity))
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
            return .applied(generation: next, declarations: declarations.map(\.identity), timeline: timeline)
        } catch let error as SpliceError {
            return .rejected(error)
        } catch {
            return .rejected(SpliceError(stage: .generate, subject: url.lastPathComponent,
                                         reason: "\(error)", recovery: .rebuild))
        }
    }
}

/// Everything that depends on the app living in a simulator container.
/// Isolated here so that the rest of the daemon does not learn about `simctl`.
struct SimulatorContainer: Sendable {
    let bundleIdentifier: String

    private func dataContainer() throws -> URL {
        let result = try Subprocess.run("/usr/bin/xcrun",
                                        arguments: ["simctl", "get_app_container", "booted", bundleIdentifier, "data"])
        let path = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw SpliceError(stage: .transfer, subject: bundleIdentifier,
                              reason: "could not find the app container: \(path)",
                              recovery: .restart)
        }
        return URL(fileURLWithPath: path)
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
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let destination = inbox.appendingPathComponent(image.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: image, to: destination)
        return destination
    }
}
