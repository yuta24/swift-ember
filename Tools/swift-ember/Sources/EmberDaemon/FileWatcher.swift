import Foundation
import EmberCore

/// Watches Swift sources for additions, saves, and removals.
///
/// This polls modification times rather than using FSEvents or a kqueue on
/// each file. Editors save atomically, by writing a temporary file and renaming
/// it over the original, which invalidates any descriptor held on the old
/// inode; a watcher built on descriptors has to notice and re-register, and
/// misses edits while it does. Comparing mtimes has no such hole. At a 150 ms
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
    private var stamps: [URL: Date] = [:]
    private var task: Task<Void, Never>?

    public init(
        roots: [URL],
        excluding excluded: [URL] = [],
        interval: Duration = .milliseconds(150)
    ) {
        self.roots = roots
        self.sourceFilter = SourcePathFilter(excluding: excluded)
        self.interval = interval
    }

    /// Records the current state without reporting it, so that files already on
    /// disk when watching starts are not mistaken for edits.
    public func prime() throws {
        let current = try scan()
        lock.withLock { stamps = current }
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
        let current = try scan()
        return lock.withLock {
            var changed = current.compactMap { url, date -> Change? in
                guard let previous = stamps[url] else {
                    return Change(url: url, kind: .added)
                }
                return previous == date ? nil : Change(url: url, kind: .modified)
            }
            for url in stamps.keys where current[url] == nil {
                changed.append(Change(url: url, kind: .removed))
            }
            stamps = current
            return changed.sorted { $0.url.path < $1.url.path }
        }
    }

    private func scan() throws -> [URL: Date] {
        var result: [URL: Date] = [:]
        var problems: [String] = []
        let manager = FileManager.default
        for root in roots {
            let root = root.standardizedFileURL
            guard !sourceFilter.excludes(root) else { continue }
            guard let walker = manager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles],
                                                  errorHandler: { url, error in
                                                      problems.append("\(url.path): \(error.localizedDescription)")
                                                      return true
                                                  }) else {
                problems.append("\(root.path): could not enumerate the source root")
                continue
            }
            for case let url as URL in walker {
                if sourceFilter.excludes(url) {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let date = values.contentModificationDate else {
                        problems.append("\(url.path): modification date is unavailable")
                        continue
                    }
                    result[url.standardizedFileURL] = date
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
