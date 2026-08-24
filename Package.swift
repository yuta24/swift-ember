// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-splice",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "swift-splice", targets: ["swift-splice"]),
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
        // The CLI is a library plus a thin main so that argument parsing can be
        // tested; an executable target cannot be imported.
        .target(name: "SpliceCLI", dependencies: ["SpliceCore", "SpliceDaemon", "SpliceGen"]),
        .executableTarget(name: "swift-splice", dependencies: ["SpliceCLI"],
                          path: "Sources/SpliceCLIMain"),
        // A development tool, deliberately not part of the swift-splice
        // product. It calls the real classifier, generator, and compiler, so
        // the numbers cannot drift from what the daemon actually does.
        .executableTarget(name: "splice-bench",
                          dependencies: ["SpliceCore", "SpliceGen", "SpliceDaemon"],
                          path: "Sources/SpliceBench"),
        .testTarget(name: "SpliceGenTests", dependencies: ["SpliceGen"]),
        .testTarget(name: "SpliceDaemonTests", dependencies: ["SpliceCore", "SpliceDaemon", "SpliceCLI"]),
        .testTarget(name: "SpliceEndToEndTests", dependencies: ["SpliceCore", "SpliceGen"]),
    ]
)
