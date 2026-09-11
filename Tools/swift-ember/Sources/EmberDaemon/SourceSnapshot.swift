import Foundation
import EmberCore

/// A complete source tree captured as text, including files excluded from
/// change delivery but still used for cross-file safety checks.
public struct SourceSnapshot: Equatable, Sendable {
    public let watched: [URL: String]
    public let excluded: [URL: String]

    public init(watched: [URL: String], excluded: [URL: String]) {
        self.watched = watched
        self.excluded = excluded
    }

    public static func capture(
        from roots: [URL],
        excluding sourceFilter: SourcePathFilter = SourcePathFilter()
    ) throws -> SourceSnapshot {
        var watched: [URL: String] = [:]
        var excluded: [URL: String] = [:]
        var problems: [String] = []
        let manager = FileManager.default

        for root in roots {
            let root = root.standardizedFileURL
            guard let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    problems.append("\(url.path): \(error.localizedDescription)")
                    return true
                }) else {
                problems.append("\(root.path): could not enumerate the source root")
                continue
            }

            for case let candidate as URL in walker where candidate.pathExtension == "swift" {
                let url = candidate.standardizedFileURL
                do {
                    let source = try String(contentsOf: url, encoding: .utf8)
                    if sourceFilter.excludes(url) {
                        excluded[url] = source
                    } else {
                        watched[url] = source
                    }
                } catch {
                    problems.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }

        guard problems.isEmpty else {
            throw FileWatcher.ScanFailure(problems: problems.sorted())
        }
        return SourceSnapshot(watched: watched, excluded: excluded)
    }
}
