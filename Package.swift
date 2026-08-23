// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-splice",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "swift-splice", targets: ["SpliceCLI"]),
        // What an application links. Everything else in this package is host
        // tooling and never reaches a device or simulator.
        .library(name: "SpliceRuntime", targets: ["SpliceRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .target(name: "SpliceCore"),
        // Debug-only by construction: without SPLICE_ENABLED the dialling,
        // loading, and watching code is not compiled, so a Release build of an
        // app that links this carries an inert entry point and nothing else.
        // That is what makes DESIGN.md section 5.3 hold without asking the
        // integrating project to remember anything.
        .target(name: "SpliceRuntime", path: "runtime/Sources",
                swiftSettings: [.define("SPLICE_ENABLED", .when(configuration: .debug))]),
        .target(name: "SpliceGen", dependencies: [
            "SpliceCore",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .target(name: "SpliceDaemon", dependencies: ["SpliceCore", "SpliceGen"]),
        .executableTarget(name: "SpliceCLI", dependencies: ["SpliceCore", "SpliceDaemon"]),
        .testTarget(name: "SpliceGenTests", dependencies: ["SpliceGen"]),
        .testTarget(name: "SpliceDaemonTests", dependencies: ["SpliceCore", "SpliceDaemon"]),
        .testTarget(name: "SpliceEndToEndTests", dependencies: ["SpliceCore", "SpliceGen"]),
    ]
)
