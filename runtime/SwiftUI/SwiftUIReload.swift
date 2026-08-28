import SwiftUI
@_spi(SpliceAdapters) import SpliceRuntime

#if SPLICE_ENABLED

@MainActor
private final class SpliceReloadObserver: ObservableObject {
    static let shared = SpliceReloadObserver()

    @Published private(set) var generation: UInt64 = 0

    private init() {
        SpliceGenerationEvents.observe { [weak self] generation in
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
public struct ObserveSplice: DynamicProperty {
    @ObservedObject private var observer = SpliceReloadObserver.shared

    public init() {}
    public var wrappedValue: Splice.Type { Splice.self }
}

@MainActor
public extension View {
    /// Pins the concrete value returned by an opted-in `body` to `AnyView`.
    ///
    /// This must be the outermost expression in the body in both the built
    /// source and every patch. The classifier enforces that boundary before it
    /// permits an otherwise-refused `some View` replacement.
    func enableSplice() -> AnyView { AnyView(self) }
}

#else

@propertyWrapper @preconcurrency @MainActor
public struct ObserveSplice: DynamicProperty {
    public init() {}
    public var wrappedValue: Splice.Type { Splice.self }
}

@MainActor
public extension View {
    /// Release builds carry no erasure or observation overhead.
    @inlinable @inline(__always)
    func enableSplice() -> Self { self }
}

#endif
