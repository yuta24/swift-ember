import Foundation

/// The framework-neutral seam used by optional UI adapters.
///
/// The core runtime knows that a generation loaded, but it must not know what
/// SwiftUI, AppKit, or any future adapter does with that fact. The SPI keeps
/// this out of the application-facing API while allowing a separate SwiftPM
/// target to subscribe without importing UI frameworks here.
@_spi(EmberAdapters)
public enum EmberGenerationEvents {
    public typealias Observer = @MainActor @Sendable (UInt64) -> Void

    /// Installs a process-lifetime observer.
    ///
    /// Adapters are process-lifetime singletons, so removal would add a token
    /// and a second lifetime model without a caller. More than one adapter may
    /// still observe; publishing copies the list under the lock and invokes it
    /// on the main actor after a successful `dlopen`.
    public static func observe(_ observer: @escaping Observer) {
        #if EMBER_ENABLED
        state.add(observer)
        #endif
    }

    static func publish(_ generation: UInt64) {
        #if EMBER_ENABLED
        let observers = state.snapshot()
        guard !observers.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for observer in observers { observer(generation) }
            }
        }
        #endif
    }

    #if EMBER_ENABLED
    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [Observer] = []

        func add(_ observer: @escaping Observer) {
            lock.withLock { observers.append(observer) }
        }

        func snapshot() -> [Observer] {
            lock.withLock { observers }
        }
    }
    #endif
}
