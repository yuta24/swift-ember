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

    public static func == (lhs: SourceSnapshot, rhs: SourceSnapshot) -> Bool {
        lhs.digests == rhs.digests && lhs.stamps == rhs.stamps && lhs.watched.keys == rhs.watched.keys
    }

    public static func capture(
        from roots: [URL],
        excluding sourceFilter: SourcePathFilter = SourcePathFilter()
    ) throws -> SourceSnapshot {
        var watched: [URL: String] = [:]
        var excluded: [URL: String] = [:]
        var digests: [String: String] = [:]
        var problems: [String] = []
        let stamps = try FileWatcher.scan(roots: roots)
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

        if problems.isEmpty {
            let after = try FileWatcher.scan(roots: roots)
            for url in Set(stamps.keys).union(after.keys) where stamps[url] != after[url] {
                problems.append("\(url.path): source changed during snapshot capture")
            }
        }
        guard problems.isEmpty else {
            throw FileWatcher.ScanFailure(problems: problems.sorted())
        }
        return SourceSnapshot(watched: watched, excluded: excluded, stamps: stamps, digests: digests)
    }

    public static func captureForStartup(
        from roots: [URL], excluding sourceFilter: SourcePathFilter = SourcePathFilter()
    ) throws -> SourceSnapshot {
        do {
            return try capture(from: roots, excluding: sourceFilter)
        } catch {
            throw EmberError(stage: .watch, subject: "source roots",
                             reason: "cannot take the initial source snapshot.\n\n\(error)",
                             recovery: .configure)
        }
    }
}
