// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-ember-tooling",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-ember", targets: ["swift-ember"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
    ],
    targets: [
        .target(name: "EmberCore"),
        .target(name: "EmberGen", dependencies: [
            "EmberCore",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .target(name: "EmberDaemon", dependencies: ["EmberCore", "EmberGen"]),
        // The CLI is a library plus a thin main so argument parsing remains
        // directly testable; executable targets cannot be imported.
        .target(name: "EmberCLI", dependencies: ["EmberCore", "EmberDaemon", "EmberGen"]),
        .executableTarget(name: "swift-ember", dependencies: ["EmberCLI"],
                          path: "Sources/EmberCLIMain"),
        // A development-only executable that exercises the production
        // classifier, generator, and compiler for representative timings.
        .executableTarget(name: "ember-bench",
                          dependencies: ["EmberCore", "EmberGen", "EmberDaemon"],
                          path: "Sources/EmberBench"),
        .testTarget(name: "EmberGenTests", dependencies: ["EmberGen"]),
        .testTarget(name: "EmberDaemonTests",
                    dependencies: ["EmberCore", "EmberDaemon", "EmberCLI"]),
        .testTarget(name: "EmberEndToEndTests", dependencies: ["EmberCore", "EmberGen"]),
    ]
)
