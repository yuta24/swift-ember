import Foundation

/// Component-aware path exclusions shared by every source-tree scan.
///
/// A directory excludes all descendants; a file excludes only itself. String
/// prefix matching alone would also exclude `SourcesExtra` for `Sources`, so
/// paths are compared with a trailing separator.
public struct SourcePathFilter: Sendable {
    private let excludedPaths: [String]

    public init(excluding urls: [URL] = []) {
        excludedPaths = Array(Set(urls.map { $0.standardizedFileURL.path })).sorted()
    }

    public func excludes(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedPaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded.hasSuffix("/") ? excluded : excluded + "/")
        }
    }
}
