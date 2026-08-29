// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-splice-tooling",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-splice", targets: ["swift-splice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
    ],
    targets: [
        .target(name: "SpliceCore"),
        .target(name: "SpliceGen", dependencies: [
            "SpliceCore",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .target(name: "SpliceDaemon", dependencies: ["SpliceCore", "SpliceGen"]),
        // The CLI is a library plus a thin main so argument parsing remains
        // directly testable; executable targets cannot be imported.
        .target(name: "SpliceCLI", dependencies: ["SpliceCore", "SpliceDaemon", "SpliceGen"]),
        .executableTarget(name: "swift-splice", dependencies: ["SpliceCLI"],
                          path: "Sources/SpliceCLIMain"),
        // A development-only executable that exercises the production
        // classifier, generator, and compiler for representative timings.
        .executableTarget(name: "splice-bench",
                          dependencies: ["SpliceCore", "SpliceGen", "SpliceDaemon"],
                          path: "Sources/SpliceBench"),
        .testTarget(name: "SpliceGenTests", dependencies: ["SpliceGen"]),
        .testTarget(name: "SpliceDaemonTests",
                    dependencies: ["SpliceCore", "SpliceDaemon", "SpliceCLI"]),
        .testTarget(name: "SpliceEndToEndTests", dependencies: ["SpliceCore", "SpliceGen"]),
    ]
)
