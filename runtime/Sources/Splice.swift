import Foundation

/// The in-app half of swift-splice.
///
/// Linked only into an explicitly enabled Debug configuration. It holds as
/// little policy as possible: it dials the daemon, loads images the daemon
/// names, and reports what happened. Whether a change is safe, what to
/// generate, and how to compile it are all decided on the host (DESIGN.md
/// section 4.3).
public enum Splice {
    public struct Status: Sendable {
        public var connected = false
        public var loadedGenerations: [UInt64] = []
        public var lines: [String] = []
    }

    private static let state = StateBox()

    /// Called once from the application.
    ///
    /// The call site needs no `#if` of its own: without `SPLICE_ENABLED` this
    /// does nothing, and nothing that dials, loads, or watches is compiled at
    /// all. Callers get one entry point that is safe in every configuration.
    public static func start(onUpdate: @escaping @Sendable (Status) -> Void = { _ in }) {
        #if SPLICE_ENABLED
        state.onUpdate = onUpdate
        let client = SpliceClient(state: state)
        state.retain(client)
        client.start()
        #endif
    }

    public static var status: Status { state.snapshot }

    /// Scans the inbox and loads anything not yet loaded.
    ///
    /// A debugging affordance for driving the runtime without a daemon, which
    /// is how M1 worked. The daemon does not use it: it names the image it
    /// wants loaded, so nothing has to be inferred from a directory listing.
    ///
    /// Declared outside the conditional section for the same reason `start()`
    /// is: a call site should not need an `#if` of its own. Nested inside it,
    /// the inner guard below was unreachable and the symbol simply vanished
    /// from a Release build, so an app calling this compiled in Debug and
    /// failed to compile shipping.
    @discardableResult
    public static func loadPendingPatches() -> [String] {
        #if !SPLICE_ENABLED
        return []
        #else
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = documents.appendingPathComponent("Patches", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []

        var reported: [String] = []
        for url in contents.filter({ $0.pathExtension == "dylib" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !state.hasLoaded(url.lastPathComponent) else { continue }
            state.markLoaded(url.lastPathComponent)
            let line: String
            if dlopen(url.path, RTLD_NOW) != nil {
                line = "\(url.lastPathComponent): loaded"
            } else {
                line = "\(url.lastPathComponent): \(String(cString: dlerror()))"
            }
            state.note(line)
            reported.append(line)
        }
        if reported.isEmpty { state.note("nothing pending") }
        return reported
        #endif
    }

    #if SPLICE_ENABLED

    // MARK: - Loading

    /// Loads one image. The only decision made in the process.
    static func load(generation: UInt64, path: String) -> LoadOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed(stage: "TRANSFER", message: "no image at \(path)")
        }
        guard dlopen(path, RTLD_NOW) != nil else {
            // dlopen failing means nothing took effect, so the process is still
            // coherently running the previous generation.
            return .failed(stage: "LOAD", message: String(cString: dlerror()))
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        state.recordLoaded(generation)
        return .loaded(generation: generation, durationMs: ms)
    }

    enum LoadOutcome {
        case loaded(generation: UInt64, durationMs: Double)
        case failed(stage: String, message: String)
    }

    #endif

    /// Shared mutable state, kept in one place so the client and the loader do
    /// not each invent their own locking.
    final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status = Status()
        var onUpdate: (@Sendable (Status) -> Void)?

        var snapshot: Status { lock.withLock { status } }

        func setConnected(_ connected: Bool) {
            let copy: Status = lock.withLock {
                status.connected = connected
                status.lines.append(connected ? "connected to the daemon" : "waiting for the daemon")
                return status
            }
            onUpdate?(copy)
        }

        func recordLoaded(_ generation: UInt64) {
            let copy: Status = lock.withLock {
                status.loadedGenerations.append(generation)
                return status
            }
            onUpdate?(copy)
        }

        func note(_ line: String) {
            let copy: Status = lock.withLock {
                status.lines.append(line)
                if status.lines.count > 8 { status.lines.removeFirst() }
                return status
            }
            onUpdate?(copy)
        }

        var generations: [UInt64] { lock.withLock { status.loadedGenerations } }

        /// Keeps the client alive for the process's lifetime. Held here rather
        /// than in a static so there is one lock guarding all of this state.
        private var client: AnyObject?
        func retain(_ object: AnyObject) { lock.withLock { client = object } }

        private var loadedNames: Set<String> = []
        func hasLoaded(_ name: String) -> Bool { lock.withLock { loadedNames.contains(name) } }
        func markLoaded(_ name: String) { lock.withLock { _ = loadedNames.insert(name) } }
    }
}
