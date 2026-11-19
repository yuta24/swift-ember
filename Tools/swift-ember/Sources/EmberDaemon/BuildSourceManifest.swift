import Foundation
import EmberCore

/// Source proof for the local link target. The sidecar lives beside the app
/// bundle so it neither modifies a signed product nor travels to the device.
public struct BuildSourceManifest {
    private struct Recorded: Codable, Equatable {
        let linkTarget: String
        let buildUUIDs: [String]
        let sha256: [String: String]
    }

    private struct BuildInputs: Codable {
        let linkTarget: String
        let previousUUIDs: [String]
        let stamps: [URL: SourceFileStamp]
        let sha256: [String: String]
    }

    private enum State: Codable {
        case building(previous: Recorded?, inputs: BuildInputs?)
        case built(Recorded)

        var lastBuild: Recorded? {
            switch self {
            case .building(let previous, _): previous
            case .built(let recorded): recorded
            }
        }
    }

    public let url: URL
    private let context: BuildContext
    private let linkTarget: String

    public init(context: BuildContext) {
        self.context = context
        // Keep the product path stable when the executable first appears.
        // Foundation's file URL standardization can change /private/tmp to
        // /tmp for an existing file while leaving a missing file untouched.
        linkTarget = URL(fileURLWithPath: context.linkTarget, isDirectory: false).standardized.path
        let executable = URL(fileURLWithPath: context.appBinaryPath, isDirectory: false).standardized
        var product = executable
        while product.path != "/", product.pathExtension != "app" {
            product.deleteLastPathComponent()
        }
        url = (product.pathExtension == "app" ? product : executable)
            .appendingPathExtension("swift-ember-sources.json")
    }

    public func snapshot() throws -> SourceSnapshot {
        try SourceSnapshot.captureForStartup(
            from: context.sourceRoots.map { URL(fileURLWithPath: $0) },
            excluding: SourcePathFilter(excluding: context.excludedSourcePaths.map {
                URL(fileURLWithPath: $0)
            }))
    }

    /// Runs before compiling. Publish the in-progress state before reading
    /// sources so a failed prepare cannot be mistaken for a legacy build.
    public func prepare() throws {
        let previous = try read(replacingMalformed: true)?.lastBuild
        try write(.building(previous: previous, inputs: nil))
        let sources = try snapshot()
        let previousUUIDs = FileManager.default.fileExists(atPath: linkTarget) ? try readUUIDs() : []
        let inputs = BuildInputs(linkTarget: linkTarget, previousUUIDs: previousUUIDs,
                                 stamps: sources.stamps, sha256: sources.digests)
        try write(.building(previous: previous, inputs: inputs))
    }

    /// Runs after a successful build. A no-op build can preserve an existing
    /// proof, but it cannot attest that newly captured inputs were compiled.
    @discardableResult
    public func record(required: Bool = true) throws -> Bool {
        guard case .building(let previous, let inputs) = try read() else {
            if required { throw failure("run `xcode prepare` before compiling and try again.") }
            return false
        }
        guard let inputs, inputs.linkTarget == linkTarget else {
            throw failure("build preparation did not capture inputs for \(linkTarget).")
        }
        let sources = try snapshot()
        let changed = Set(inputs.stamps.keys).union(sources.stamps.keys).filter { url in
            inputs.stamps[url] != sources.stamps[url] || inputs.sha256[url.path] != sources.digests[url.path]
        }.map(\.path)
        guard changed.isEmpty else {
            throw failure("Swift sources changed during the build:\n\(paths(changed))")
        }
        let recorded = Recorded(linkTarget: linkTarget, buildUUIDs: try readUUIDs(), sha256: sources.digests)
        guard recorded.buildUUIDs != inputs.previousUUIDs || recorded == previous else {
            throw failure("the UUIDs at \(linkTarget) did not change and there is no matching source proof. Clean the build products before rebuilding.")
        }
        try write(.built(recorded))
        return true
    }

    /// Returns nil only for a legacy product with no sidecar. A present but
    /// incomplete, stale, or unreadable proof always refuses startup.
    public func validate(_ snapshot: SourceSnapshot) throws -> [String]? {
        guard let state = try read() else { return nil }
        guard case .built(let recorded) = state else {
            throw failure("the build did not finish recording source hashes. Complete a build with the configured pre- and post-actions.")
        }
        let uuids = try readUUIDs()
        guard recorded.buildUUIDs == uuids, recorded.linkTarget == linkTarget else {
            throw failure("the source manifest does not match the Mach-O UUIDs at \(linkTarget). Rebuild with source recording enabled.")
        }
        let changed = Set(recorded.sha256.keys).union(snapshot.digests.keys).filter {
            recorded.sha256[$0] != snapshot.digests[$0]
        }
        guard changed.isEmpty else {
            throw failure("Swift sources differ from the build:\n\(paths(Array(changed)))")
        }
        return uuids
    }

    private func readUUIDs() throws -> [String] {
        let uuids = BuildUUID.read(from: linkTarget).sorted()
        guard !uuids.isEmpty else { throw failure("cannot read the Mach-O UUIDs at \(linkTarget).") }
        return uuids
    }

    private func read(replacingMalformed: Bool = false) throws -> State? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(State.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch is DecodingError where replacingMalformed {
            return nil
        } catch {
            throw failure("cannot read the build source manifest: \(error.localizedDescription)")
        }
    }

    private func write(_ state: State) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            throw EmberError(stage: .watch, subject: url.path,
                             reason: "cannot write the build source manifest: \(error.localizedDescription)",
                             recovery: .configure)
        }
    }

    private func failure(_ reason: String) -> EmberError {
        EmberError(stage: .watch, subject: url.path, reason: reason, recovery: .rebuild)
    }

    private func paths(_ changed: [String]) -> String {
        changed.sorted().map { "  \($0)" }.joined(separator: "\n")
    }
}
