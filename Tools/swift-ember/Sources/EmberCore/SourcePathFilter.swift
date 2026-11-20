import Foundation

/// Component-aware path exclusions shared by every source-tree scan.
///
/// Configured paths exclude a whole subtree even if they do not exist yet.
/// Known source files can be excluded by exact path.
public struct SourcePathFilter: Sendable {
    private let exactPaths: Set<String>
    private let directoryPrefixes: [String]

    public init(excluding urls: [URL] = [], excludingFiles files: [URL] = []) {
        let roots = Set(urls.map { $0.standardizedFileURL.path })
        exactPaths = roots.union(files.map { $0.standardizedFileURL.path })
        // The separator keeps Sources and SourcesExtra independent.
        directoryPrefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    public func excludes(_ url: URL) -> Bool {
        excludes(standardizedPath: url.standardizedFileURL.path)
    }

    public func excludes(standardizedPath path: String) -> Bool {
        exactPaths.contains(path) || directoryPrefixes.contains { path.hasPrefix($0) }
    }
}
