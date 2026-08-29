// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-splice",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        // The root package is intentionally application-only. Host tooling
        // lives in Tools/swift-splice so adding either library to an Xcode
        // project does not resolve or build SwiftSyntax.
        .library(name: "SpliceRuntime", targets: ["SpliceRuntime"]),
        // Opt-in SwiftUI support. Kept out of SpliceRuntime so a UIKit-only
        // application does not acquire a SwiftUI/Combine dependency merely by
        // enabling the core loader.
        .library(name: "SpliceSwiftUI", targets: ["SpliceSwiftUI"]),
    ],
    targets: [
        // Debug-only by construction: without SPLICE_ENABLED the dialling,
        // loading, and watching code is not compiled, so a Release build of an
        // app that links this carries an inert entry point and nothing else.
        // That is what makes DESIGN.md section 5.3 hold without asking the
        // integrating project to remember anything.
        .target(name: "SpliceRuntime", path: "runtime/Sources",
                swiftSettings: [.define("SPLICE_ENABLED", .when(configuration: .debug))]),
        .target(name: "SpliceSwiftUI", dependencies: ["SpliceRuntime"],
                path: "runtime/SwiftUI",
                swiftSettings: [.define("SPLICE_ENABLED", .when(configuration: .debug))]),
    ]
)
