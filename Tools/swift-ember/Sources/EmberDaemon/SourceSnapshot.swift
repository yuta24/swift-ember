import Foundation
import CryptoKit
import EmberCore

/// A complete source tree captured as text, including files excluded from
/// change delivery but still used for cross-file safety checks.
public struct SourceSnapshot: Equatable, Sendable {
    public let watched: [URL: String]
    public let excluded: [URL: String]
    let stamps: [URL: SourceFileStamp]
    let digests: [String: String]

    private struct UnstableSources: Error, CustomStringConvertible {
        let paths: [String]

        var description: String {
            "Swift sources changed during snapshot capture:\n"
                + paths.map { "  \($0)" }.joined(separator: "\n")
        }
    }

    public static func == (lhs: SourceSnapshot, rhs: SourceSnapshot) -> Bool {
        lhs.digests == rhs.digests && lhs.stamps == rhs.stamps && lhs.watched.keys == rhs.watched.keys
    }

    public static func capture(
        from roots: [URL],
        excluding sourceFilter: SourcePathFilter = SourcePathFilter(),
        ignoring ignored: SourcePathFilter = SourcePathFilter(),
        skippingSource: (URL) -> Bool = { _ in false }
    ) throws -> SourceSnapshot {
        try capture(excluding: sourceFilter) {
            try FileWatcher.scan(roots: roots, excluding: ignored, skippingSource: skippingSource)
        }
    }

    private static func capture(
        excluding sourceFilter: SourcePathFilter,
        scan: () throws -> [URL: SourceFileStamp]
    ) throws -> SourceSnapshot {
        var watched: [URL: String] = [:]
        var excluded: [URL: String] = [:]
        var digests: [String: String] = [:]
        var problems: [String] = []
        let stamps = try scan()
        for url in stamps.keys {
            do {
                let data = try Data(contentsOf: url)
                guard let source = String(data: data, encoding: .utf8) else {
                    problems.append("\(url.path): invalid UTF-8")
                    continue
                }
                if sourceFilter.excludes(url) {
                    excluded[url] = source
                } else {
                    watched[url] = source
                }
                digests[url.path] = Data(SHA256.hash(data: data)).base64EncodedString()
            } catch {
                problems.append("\(url.path): \(error.localizedDescription)")
            }
        }

        guard problems.isEmpty else {
            throw FileWatcher.ScanFailure(problems: problems.sorted())
        }
        let after = try scan()
        let changed = Set(stamps.keys).union(after.keys)
            .filter { stamps[$0] != after[$0] }.map(\.path).sorted()
        guard changed.isEmpty else { throw UnstableSources(paths: changed) }
        return SourceSnapshot(watched: watched, excluded: excluded, stamps: stamps, digests: digests)
    }

    public static func captureForStartup(
        from roots: [URL], excluding sourceFilter: SourcePathFilter = SourcePathFilter(),
        ignoring ignored: SourcePathFilter = SourcePathFilter(),
        skippingSource: (URL) -> Bool = { _ in false }
    ) throws -> SourceSnapshot {
        try captureForStartup(excluding: sourceFilter) {
            try FileWatcher.scan(roots: roots, excluding: ignored, skippingSource: skippingSource)
        }
    }

    static func captureForStartup(
        excluding sourceFilter: SourcePathFilter = SourcePathFilter(),
        scan: () throws -> [URL: SourceFileStamp]
    ) throws -> SourceSnapshot {
        var retries = 2
        while true {
            do {
                return try capture(excluding: sourceFilter, scan: scan)
            } catch let unstable as UnstableSources {
                guard retries > 0 else {
                    throw EmberError(stage: .watch, subject: "source roots",
                                     reason: "sources did not settle after three snapshot attempts.\n\n\(unstable)",
                                     recovery: .retry)
                }
                retries -= 1
                Thread.sleep(forTimeInterval: 0.05)
            } catch {
                throw EmberError(stage: .watch, subject: "source roots",
                                 reason: "cannot take the initial source snapshot.\n\n\(error)",
                                 recovery: .configure)
            }
        }
    }
}
