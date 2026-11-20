import Foundation
import System

/// Files managed by init must resolve beneath the directory that owns them.
struct InitPaths {
    struct Entry {
        let url: URL
        let exists: Bool
    }

    let root: URL

    init(root: URL) throws {
        self.root = try Self.resolve(root).url
    }

    func validate(_ candidate: URL) throws -> Entry {
        let resolved = try Self.resolve(candidate)
        let path = resolved.url.path
        let filePath = FilePath(path)
        let rootPath = FilePath(root.path)
        if filePath.lexicallyNormalized().starts(with: rootPath), filePath != rootPath {
            let checked = URL(fileURLWithPath: path, isDirectory: resolved.url.hasDirectoryPath)
            return Entry(url: checked, exists: resolved.exists)
        }
        throw InitError("\(candidate.path) is outside \(root.path)")
    }

    private static func resolve(_ candidate: URL) throws -> Entry {
        var ancestor = candidate.standardizedFileURL
        var missing: [String] = []
        while true {
            let resolved = ancestor.resolvingSymlinksInPath()
            do {
                let values = try resolved.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink == false else {
                    throw InitError("cannot resolve symbolic link at \(ancestor.path)")
                }
                let path = missing.reversed().reduce(resolved) { $0.appendingPathComponent($1) }.path
                let url = URL(fileURLWithPath: path, isDirectory: candidate.hasDirectoryPath)
                return Entry(url: url, exists: missing.isEmpty)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // Foundation leaves symlinks unresolved when a leaf is missing.
                // Resolve the existing ancestor before rebuilding the missing suffix.
                guard ancestor.path != "/" else { throw error }
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
        }
    }
}
