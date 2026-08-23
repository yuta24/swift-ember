// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-splice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-splice", targets: ["SpliceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .target(name: "SpliceCore"),
        .target(name: "SpliceGen", dependencies: [
            "SpliceCore",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .target(name: "SpliceDaemon", dependencies: ["SpliceCore", "SpliceGen"]),
        .executableTarget(name: "SpliceCLI", dependencies: ["SpliceCore", "SpliceDaemon"]),
        .testTarget(name: "SpliceGenTests", dependencies: ["SpliceGen"]),
    ]
)
