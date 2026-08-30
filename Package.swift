// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-ember",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        // The root package is intentionally application-only. Host tooling
        // lives in Tools/swift-ember so adding either library to an Xcode
        // project does not resolve or build SwiftSyntax.
        .library(name: "EmberRuntime", targets: ["EmberRuntime"]),
        // Opt-in SwiftUI support. Kept out of EmberRuntime so a UIKit-only
        // application does not acquire a SwiftUI/Combine dependency merely by
        // enabling the core loader.
        .library(name: "EmberSwiftUI", targets: ["EmberSwiftUI"]),
    ],
    targets: [
        // Debug-only by construction: without EMBER_ENABLED the dialling,
        // loading, and watching code is not compiled, so a Release build of an
        // app that links this carries an inert entry point and nothing else.
        // That is what makes DESIGN.md section 5.3 hold without asking the
        // integrating project to remember anything.
        .target(name: "EmberRuntime", path: "runtime/Sources",
                swiftSettings: [.define("EMBER_ENABLED", .when(configuration: .debug))]),
        .target(name: "EmberSwiftUI", dependencies: ["EmberRuntime"],
                path: "runtime/SwiftUI",
                swiftSettings: [.define("EMBER_ENABLED", .when(configuration: .debug))]),
    ]
)
