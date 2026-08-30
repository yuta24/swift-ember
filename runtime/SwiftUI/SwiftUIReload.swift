import SwiftUI
@_spi(EmberAdapters) import EmberRuntime

#if EMBER_ENABLED

@MainActor
private final class EmberReloadObserver: ObservableObject {
    static let shared = EmberReloadObserver()

    @Published private(set) var generation: UInt64 = 0

    private init() {
        EmberGenerationEvents.observe { [weak self] generation in
            self?.generation = generation
        }
    }
}

/// Invalidates the enclosing SwiftUI `View` after a patch loads.
///
/// The wrapped value is intentionally uninteresting. SwiftUI discovers the
/// nested `@ObservedObject` through `DynamicProperty`; a body need not mention
/// the property for a generation change to make that body run again.
@propertyWrapper @preconcurrency @MainActor
public struct ObserveEmber: DynamicProperty {
    @ObservedObject private var observer = EmberReloadObserver.shared

    public init() {}
    public var wrappedValue: Ember.Type { Ember.self }
}

@MainActor
public extension View {
    /// Pins the concrete value returned by an opted-in `body` to `AnyView`.
    ///
    /// This must be the outermost expression in the body in both the built
    /// source and every patch. The classifier enforces that boundary before it
    /// permits an otherwise-refused `some View` replacement.
    func emberable() -> AnyView { AnyView(self) }
}

#else

@propertyWrapper @preconcurrency @MainActor
public struct ObserveEmber: DynamicProperty {
    public init() {}
    public var wrappedValue: Ember.Type { Ember.self }
}

@MainActor
public extension View {
    /// Release builds carry no erasure or observation overhead.
    @inlinable @inline(__always)
    func emberable() -> Self { self }
}

#endif
