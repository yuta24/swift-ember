import Darwin
import Foundation
import EmberCore

/// Watches Swift sources for additions, saves, and removals.
///
/// This polls file metadata rather than using FSEvents or a kqueue on
/// each file. Editors save atomically, by writing a temporary file and renaming
/// it over the original, which invalidates any descriptor held on the old
/// inode; a watcher built on descriptors has to notice and re-register, and
/// misses edits while it does. Comparing inode and change times covers atomic
/// replacements and saves with preserved modification times. At a 150 ms
/// interval it also lands inside the sub-100-ms-ish detection budget in PRD.md
/// section 10 often enough for M2.
public final class FileWatcher: @unchecked Sendable {
    public struct ScanFailure: Error, Equatable, Sendable, CustomStringConvertible {
        public let problems: [String]

        public init(problems: [String]) {
            self.problems = problems
        }

        public var description: String {
            "cannot scan watched sources reliably:\n"
                + problems.map { "  \($0)" }.joined(separator: "\n")
        }
    }

    public struct Change: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case added
            case modified
            case removed
        }

        public let url: URL
        public let kind: Kind

        public init(url: URL, kind: Kind) {
            self.url = url
            self.kind = kind
        }
    }

    private let roots: [URL]
    private let sourceFilter: SourcePathFilter
    private let interval: Duration
    private let lock = NSLock()
    private var stamps: [URL: SourceFileStamp] = [:]
    private var task: Task<Void, Never>?

    public init(
        roots: [URL],
        excluding excluded: [URL] = [],
        excludingFiles files: [URL] = [],
        interval: Duration = .milliseconds(150)
    ) {
        self.roots = roots
        self.sourceFilter = SourcePathFilter(excluding: excluded, excludingFiles: files)
        self.interval = interval
    }

    /// Records the current state without reporting it, so that files already on
    /// disk when watching starts are not mistaken for edits.
    public func prime() throws {
        let current = try Self.scan(roots: roots, excluding: sourceFilter)
        lock.withLock { stamps = current }
    }

    /// Use the metadata captured with the validated text. A second scan here
    /// would acknowledge a save without letting the coordinator see it.
    public func prime(from snapshot: SourceSnapshot) {
        lock.withLock {
            stamps = snapshot.stamps.filter {
                snapshot.watched[$0.key] != nil && !sourceFilter.excludes(standardizedPath: $0.key.path)
            }
        }
    }

    public func start(
        onScanFailure: @escaping @Sendable (ScanFailure) -> Void = { _ in },
        onChange: @escaping @Sendable ([Change]) -> Void
    ) {
        task = Task.detached { [weak self] in
            guard let self else { return }
            var reportedFailure: ScanFailure?
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    break
                }

                do {
                    let changed = try self.poll()
                    reportedFailure = nil
                    if !changed.isEmpty { onChange(changed) }
                } catch let failure as ScanFailure {
                    if failure != reportedFailure {
                        onScanFailure(failure)
                        reportedFailure = failure
                    }
                } catch {
                    // `scan()` owns every error path today. Preserve the same
                    // fail-closed behavior if another one is added later.
                    let failure = ScanFailure(problems: [String(describing: error)])
                    if failure != reportedFailure {
                        onScanFailure(failure)
                        reportedFailure = failure
                    }
                }
            }
        }
    }

    public func stop() { task?.cancel() }

    func poll() throws -> [Change] {
        // Do not compare or advance `stamps` unless every root and file was
        // scanned. An omitted entry means "removed" only in a complete
        // snapshot; during an I/O error it means "unknown".
        let current = try Self.scan(roots: roots, excluding: sourceFilter)
        return lock.withLock {
            var changed = current.compactMap { url, stamp -> Change? in
                guard let previous = stamps[url] else {
                    return Change(url: url, kind: .added)
                }
                return previous == stamp ? nil : Change(url: url, kind: .modified)
            }
            for url in stamps.keys where current[url] == nil {
                changed.append(Change(url: url, kind: .removed))
            }
            stamps = current
            return changed.sorted { $0.url.path < $1.url.path }
        }
    }

    static func scan(
        roots: [URL], excluding sourceFilter: SourcePathFilter = SourcePathFilter(),
        skippingSource: (URL) -> Bool = { _ in false }
    ) throws -> [URL: SourceFileStamp] {
        var result: [URL: SourceFileStamp] = [:]
        var problems: [String] = []
        let manager = FileManager.default
        for root in roots {
            let root = root.standardizedFileURL
            let rootPath = root.path
            guard !sourceFilter.excludes(standardizedPath: rootPath) else { continue }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                problems.append("\(rootPath): source root is missing, inaccessible, or not a directory")
                continue
            }
            guard let walker = manager.enumerator(at: root,
                                                  includingPropertiesForKeys: [],
                                                  options: [.skipsHiddenFiles],
                                                  errorHandler: { url, error in
                                                      problems.append("\(url.path): \(error.localizedDescription)")
                                                      return true
                                                  }) else {
                problems.append("\(rootPath): could not enumerate the source root")
                continue
            }
            for case let url as URL in walker {
                let standardized = url.standardizedFileURL
                if sourceFilter.excludes(standardizedPath: standardized.path) {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift", !skippingSource(url) else { continue }
                do {
                    if let stamp = try SourceFileStamp.read(from: url) {
                        result[standardized] = stamp
                    }
                } catch {
                    problems.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }
        guard problems.isEmpty else {
            throw ScanFailure(problems: Array(Set(problems)).sorted())
        }
        return result
    }
}

struct SourceFileStamp: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    static func read(from url: URL) throws -> SourceFileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFDIR { return nil }
        guard type == S_IFREG else { throw POSIXError(.EINVAL) }
        return SourceFileStamp(
            device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}
