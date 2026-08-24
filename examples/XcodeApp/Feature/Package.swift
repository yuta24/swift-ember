// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Feature",
    platforms: [.iOS(.v18)],
    products: [.library(name: "Feature", targets: ["Feature"])],
    targets: [
        .target(
            name: "Feature",
            swiftSettings: [
                // Xcode propagates SWIFT_OPTIMIZATION_LEVEL and
                // SWIFT_ENABLE_TESTABILITY into package targets but not
                // OTHER_SWIFT_FLAGS, so the setting that makes declarations
                // replaceable has to be asked for here. Debug only, and
                // unsafeFlags is acceptable because a local package is never
                // resolved as a versioned dependency.
                .unsafeFlags(["-Xfrontend", "-enable-implicit-dynamic"],
                             .when(configuration: .debug))
            ])
    ]
)
