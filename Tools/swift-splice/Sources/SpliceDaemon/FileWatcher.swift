import Foundation

/// Watches Swift sources for saves.
///
/// This polls modification times rather than using FSEvents or a kqueue on
/// each file. Editors save atomically, by writing a temporary file and renaming
/// it over the original, which invalidates any descriptor held on the old
/// inode; a watcher built on descriptors has to notice and re-register, and
/// misses edits while it does. Comparing mtimes has no such hole. At a 150 ms
/// interval it also lands inside the sub-100-ms-ish detection budget in PRD.md
/// section 10 often enough for M2.
public final class FileWatcher: @unchecked Sendable {
    private let roots: [URL]
    private let interval: Duration
    private let lock = NSLock()
    private var stamps: [URL: Date] = [:]
    private var task: Task<Void, Never>?

    public init(roots: [URL], interval: Duration = .milliseconds(150)) {
        self.roots = roots
        self.interval = interval
    }

    /// Records the current state without reporting it, so that files already on
    /// disk when watching starts are not mistaken for edits.
    public func prime() {
        let current = scan()
        lock.withLock { stamps = current }
    }

    public func start(onChange: @escaping @Sendable ([URL]) -> Void) {
        task = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                let changed = self.poll()
                if !changed.isEmpty { onChange(changed) }
            }
        }
    }

    public func stop() { task?.cancel() }

    private func poll() -> [URL] {
        let current = scan()
        return lock.withLock {
            let changed = current.compactMap { url, date -> URL? in
                stamps[url] == date ? nil : url
            }
            stamps = current
            return changed.sorted { $0.path < $1.path }
        }
    }

    private func scan() -> [URL: Date] {
        var result: [URL: Date] = [:]
        let manager = FileManager.default
        for root in roots {
            guard let walker = manager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let date = values?.contentModificationDate {
                    result[url.standardizedFileURL] = date
                }
            }
        }
        return result
    }
}
