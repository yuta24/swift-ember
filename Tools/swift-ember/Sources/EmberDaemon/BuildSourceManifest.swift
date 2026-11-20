import Foundation
import EmberCore

/// Source proof for the local link target. The sidecar lives beside the app
/// bundle so it neither modifies a signed product nor travels to the device.
public struct BuildSourceManifest: Sendable {
    private struct Recorded: Codable, Equatable {
        let linkTarget: String
        let buildUUIDs: [String]
        var sha256: [String: String]
    }

    private struct BuildInputs: Codable {
        let linkTarget: String
        let previousUUIDs: [String]
        // Decode older in-progress records so record() can explain how to recover.
        let stamps: [URL: SourceFileStamp]?
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
    private let roots: [URL]
    private let safetyExclusions: SourcePathFilter
    private let buildOutputs: SourcePathFilter
    private let proofExclusions: SourcePathFilter
    private let linkTarget: String
    private let usesXcode: Bool

    public init(context: BuildContext) {
        usesXcode = context.xcodeSourceTargets != nil
        roots = context.sourceRoots.map { URL(fileURLWithPath: $0) }
        safetyExclusions = SourcePathFilter(excluding: context.excludedSourcePaths.map { URL(fileURLWithPath: $0) })
        buildOutputs = SourcePathFilter(excluding: context.buildOutputPaths.map { URL(fileURLWithPath: $0) })
        proofExclusions = SourcePathFilter(excluding: context.unwatchedSourcePaths.map { URL(fileURLWithPath: $0) })
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

    public func snapshot(skippingSource: (URL) -> Bool = { _ in false }) async throws -> SourceSnapshot {
        try await SourceSnapshot.captureForStartup(
            from: roots, excluding: safetyExclusions, ignoring: buildOutputs, skippingSource: skippingSource)
    }

    private func captureProof() async throws -> SourceSnapshot {
        try await SourceSnapshot.captureForStartup(from: roots, ignoring: proofExclusions)
    }

    private func proofDigests(_ digests: [String: String]) -> [String: String] {
        digests.filter { !proofExclusions.excludes(URL(fileURLWithPath: $0.key)) }
    }

    private func changedKeys<Key: Hashable, Value: Equatable>(
        from before: [Key: Value], to after: [Key: Value]
    ) -> Set<Key> {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// Runs before compiling. Publish the in-progress state before reading
    /// sources so a failed prepare cannot be mistaken for a legacy build.
    public func prepare() async throws {
        let previous = try read(replacingMalformed: true)?.lastBuild
        try write(.building(previous: previous, inputs: nil))
        let sources = try await captureProof()
        let previousUUIDs = FileManager.default.fileExists(atPath: linkTarget) ? try readUUIDs() : []
        let inputs = BuildInputs(linkTarget: linkTarget, previousUUIDs: previousUUIDs,
                                 stamps: sources.stamps, sha256: sources.digests)
        try write(.building(previous: previous, inputs: inputs))
    }

    /// Runs after a successful build. A no-op build can preserve an existing
    /// proof, but it cannot attest that newly captured inputs were compiled.
    @discardableResult
    public func record(required: Bool = true) async throws -> Bool {
        guard case .building(var previous, let inputs) = try read() else {
            if required { throw failure("run `xcode prepare` before compiling and try again.") }
            return false
        }
        guard let inputs, inputs.linkTarget == linkTarget else {
            throw failure("build preparation did not capture inputs for \(linkTarget). Run `xcode prepare` and rebuild.")
        }
        guard let stamps = inputs.stamps else {
            throw failure("build preparation did not record source metadata. Run `xcode prepare` with the current swift-ember and rebuild.")
        }
        let sources = try await captureProof()
        var changed = changedKeys(from: proofDigests(inputs.sha256), to: sources.digests)
        // A source can return to its original bytes after the compiler reads it.
        let proofStamps = stamps.filter { !proofExclusions.excludes($0.key) }
        changed.formUnion(changedKeys(from: proofStamps, to: sources.stamps).map(\.path))
        guard changed.isEmpty else {
            throw failure("""
                Swift sources changed during the build:
                \(paths(changed))

                Rebuild after edits stop. If a build phase rewrites Swift files, even with identical contents,
                add their paths to `--exclude` (or the project configuration) for both build actions and the watcher.
                """)
        }
        if let digests = previous?.sha256 { previous?.sha256 = proofDigests(digests) }
        let recorded = Recorded(linkTarget: linkTarget, buildUUIDs: try readUUIDs(), sha256: sources.digests)
        guard recorded.buildUUIDs != inputs.previousUUIDs || recorded == previous else {
            throw failure("the UUIDs at \(linkTarget) did not change and there is no matching source proof. Clean the build products before rebuilding.")
        }
        try write(.built(recorded))
        return true
    }

    /// Returns nil only for a legacy product with no sidecar. A present but
    /// incomplete, stale, or unreadable proof always refuses startup.
    public func validate(_ snapshot: SourceSnapshot, skippingSource: (URL) -> Bool = { _ in false }) throws -> [String]? {
        guard let state = try read() else { return nil }
        guard case .built(let recorded) = state else {
            throw failure("the build did not finish recording source hashes. Check the build's `xcode prepare` and `xcode record` diagnostics, then rebuild with both actions enabled.")
        }
        let uuids = try readUUIDs()
        guard recorded.buildUUIDs == uuids, recorded.linkTarget == linkTarget else {
            throw failure("the source manifest does not match the Mach-O UUIDs at \(linkTarget). Rebuild with source recording enabled.")
        }
        let changed = changedKeys(from: proofDigests(recorded.sha256), to: proofDigests(snapshot.digests))
            .filter { !skippingSource(URL(fileURLWithPath: $0)) }
        guard changed.isEmpty else {
            let includesXcodeOutputs = usesXcode && changed.contains {
                $0.contains("/Build/Intermediates.noindex/") || $0.contains("/Build/Products/")
                    || $0.contains("/SourcePackages/checkouts/")
            }
            let hint = includesXcodeOutputs
                ? "\n\n\(XcodeProject.derivedDataPathHint)"
                : ""
            throw failure("Swift sources differ from the build:\n\(paths(changed))\(hint)")
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

    private func paths(_ changed: Set<String>) -> String {
        changed.sorted().map { "  \($0)" }.joined(separator: "\n")
    }
}
