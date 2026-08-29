#if SPLICE_ENABLED

import Foundation

/// Shared by the simulator socket client and the physical-device file client.
/// Keeping validation and refresh here prevents the two transports from
/// developing different definitions of a successful reload.
final class RuntimePatchApplier: @unchecked Sendable {
    private let state: Splice.StateBox
    private let lock = NSLock()
    private var expectedBuildIdentity = ""
    private var expectedBuildUUIDs: [String] = []

    init(state: Splice.StateBox) { self.state = state }

    func expect(buildIdentity: String, buildUUIDs: [String]) {
        lock.withLock {
            expectedBuildIdentity = buildIdentity
            expectedBuildUUIDs = buildUUIDs
        }
    }

    func apply(_ request: LoadPatchRequest) -> LoadPatchResult {
        let expected = lock.withLock { (expectedBuildIdentity, expectedBuildUUIDs) }
        if request.buildIdentity != expected.0 {
            state.note("refused g\(request.generation): built for a different binary")
            return .rejected(reason: """
                the patch was built for \(request.buildIdentity) and this process is \
                \(expected.0); rebuild and relaunch
                """)
        }

        if !LoadedImages.running(oneOf: request.buildUUIDs) || request.buildUUIDs != expected.1 {
            state.note("refused g\(request.generation): this process is a different build")
            return .rejected(reason: """
                this process is not running the binary the patch was linked against. \
                It was built again after the app launched; relaunch it.
                """)
        }

        switch Splice.load(generation: request.generation, path: request.path) {
        case .loaded(let generation, let durationMs, let registered):
            let names = request.declarations.joined(separator: ", ")
            state.note("g\(generation): \(names.isEmpty ? "loaded" : names)")
            return .loaded(generation: generation, durationMs: durationMs, registered: registered,
                           refreshed: refreshUIKit())
        case .failed(let stage, let message):
            state.note("g\(request.generation) failed at \(stage): \(message)")
            return .failed(stage: stage, message: message)
        }
    }

    private func refreshUIKit() -> String? {
        #if canImport(UIKit) && !os(watchOS)
        let options = state.refresh
        guard !options.isEmpty else { return nil }

        final class Holder: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let holder = Holder()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { holder.value = UIKitRefresh.perform(options) }
            finished.signal()
        }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            return "still running; the main thread did not answer within 2 s"
        }
        return holder.value
        #else
        return nil
        #endif
    }
}

#endif
