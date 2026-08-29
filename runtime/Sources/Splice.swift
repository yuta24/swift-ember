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

    /// What to do to a UIKit application after a generation loads, so that a
    /// replaced body is not only in the process but on the screen.
    ///
    /// Declared unconditionally, like `start` and `loadPendingPatches` below,
    /// so a call site needs no `#if` of its own. On a platform with no UIKit
    /// nothing reads it.
    public struct RefreshOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Invalidate layout, constraints, and drawing, then lay out.
        ///
        /// `layoutSubviews`, `draw(_:)` and `viewWillLayoutSubviews` are
        /// measured as reached (`fixtures/Cases/uikit-live-instance`).
        /// `setNeedsUpdateConstraints` is sent for the same reason and no
        /// fixture covers it. Nothing is discarded.
        public static let layout = RefreshOptions(rawValue: 1 << 0)
        /// `reloadData()` on every table and collection view, which is what
        /// calls a data source method again. Selection is lost.
        public static let data = RefreshOptions(rawValue: 1 << 1)
        // There is deliberately no tier that re-runs `viewDidLoad`.
        //
        // Discarding a controller's view does re-run it -- the fixture
        // `uikit-view-did-load` measures exactly that, and the controller's own
        // state survives. What the fixture does not measure, and what killed
        // the idea, is putting the new view back: a controller's view is held
        // by whatever installed it, so the replacement is built and never
        // reaches the screen. Tried against the example app, it left a black
        // window -- the SwiftUI hosting controller's view was discarded and
        // nothing rebuilt it. An edit to `viewDidLoad` reaches controllers
        // created after it instead, which is what `watch` says.

        public static let `default`: RefreshOptions = [.layout, .data]
        public static let none: RefreshOptions = []
    }

    private static let state = StateBox()

    /// Called once from the application.
    ///
    /// The call site needs no `#if` of its own: without `SPLICE_ENABLED` this
    /// does nothing, and nothing that dials, loads, or watches is compiled at
    /// all. Callers get one entry point that is safe in every configuration.
    public static func start(refresh: RefreshOptions = .default,
                             onUpdate: @escaping @Sendable (Status) -> Void = { _ in }) {
        #if SPLICE_ENABLED
        state.onUpdate = onUpdate
        state.refresh = refresh
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        let client = SpliceDeviceClient(state: state)
        #else
        let client = SpliceClient(state: state)
        #endif
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
            let generation = UInt64(state.generations.count + 1)
            switch load(generation: generation, path: url.path) {
            case .loaded:
                line = "\(url.lastPathComponent): loaded"
            case .failed(_, let message):
                line = "\(url.lastPathComponent): \(message)"
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
    ///
    /// Both failures here mean nothing took effect: a missing file was never
    /// opened, and a failed `dlopen` leaves the process running the previous
    /// generation -- dyld unmaps an image it could not finish binding. The
    /// daemon relies on that to tell "this reload did not happen" from "this
    /// process can no longer be described", so a future failure mode that
    /// cannot make the same promise must report a different stage rather than
    /// reuse these.
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
        SpliceGenerationEvents.publish(generation)
        return .loaded(generation: generation, durationMs: ms,
                       registered: RegisteredReplacements.count(inImageAt: path))
    }

    enum LoadOutcome {
        case loaded(generation: UInt64, durationMs: Double, registered: Int?)
        case failed(stage: String, message: String)
    }

    #endif

    /// Shared mutable state, kept in one place so the client and the loader do
    /// not each invent their own locking.
    final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status = Status()

        /// Guarded like everything else here. It is written by the application
        /// from `start()` and read from the runtime's own queue, so a second
        /// `start()` -- a scene delegate, a preview, a test -- raced an
        /// assignment against a read.
        private var updateHandler: (@Sendable (Status) -> Void)?
        var onUpdate: (@Sendable (Status) -> Void)? {
            get { lock.withLock { updateHandler } }
            set { lock.withLock { updateHandler = newValue } }
        }

        private var refreshOptions = RefreshOptions.default
        var refresh: RefreshOptions {
            get { lock.withLock { refreshOptions } }
            set { lock.withLock { refreshOptions = newValue } }
        }

        var snapshot: Status { lock.withLock { status } }

        func setConnected(_ connected: Bool) {
            let copy: Status = lock.withLock {
                status.connected = connected
                status.lines.append(connected ? "connected to the daemon" : "waiting for the daemon")
                // The same cap `note` applies. Without it this array grew by one
                // entry a second for as long as no daemon was running, and every
                // update copied the whole of it.
                if status.lines.count > 8 { status.lines.removeFirst() }
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
