import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

/// Which module a file belongs to, and whether that module can be patched at
/// all.
///
/// The second question exists because Xcode does not answer the first one:
/// `xcodebuild -showBuildSettings` reports only the scheme's targets, and a
/// local Swift package's targets are not among them. It also does not pass
/// `OTHER_SWIFT_FLAGS` into package targets, so a package compiles without
/// implicit dynamic and produces no replacement keys while every visible build
/// setting still says the project is configured. Reading the keys back out of
/// the binary is the only check that notices.

// MARK: - Reading modules out of mangled symbols

@Test func theModuleComesOutOfAMangledSymbol() {
    #expect(ModuleInventory.moduleName(ofMangled: "_$s7Feature7GreeterV8greetingSSyFTx") == "Feature")
    #expect(ModuleInventory.moduleName(ofMangled: "$s8XcodeApp4CartC13subtotalLabelSSyFTx") == "XcodeApp")
    // A name of ten or more characters, where the length prefix is itself
    // multi-digit and a one-character read would give the wrong answer.
    #expect(ModuleInventory.moduleName(ofMangled: "_$s10FeatureKit7GreeterV1fyyFTx") == "FeatureKit")
}

@Test func nonSwiftSymbolsAreIgnored() {
    #expect(ModuleInventory.moduleName(ofMangled: "_objc_msgSend") == nil)
    #expect(ModuleInventory.moduleName(ofMangled: "_$s") == nil)
    #expect(ModuleInventory.moduleName(ofMangled: "") == nil)
    // A length that runs past the end is not a module.
    #expect(ModuleInventory.moduleName(ofMangled: "_$s99Short") == nil)
}

@Test func aBinaryThatCannotBeReadHasNoModules() {
    // Not a crash and not an empty success: an unreadable binary means nothing
    // is patchable, which is the refusing direction.
    let inventory = ModuleInventory.read(from: "/does/not/exist")
    #expect(inventory.patchableModules.isEmpty)
    #expect(inventory.isPatchable("Anything") == false)
}

// MARK: - Mapping a file to its module

private func moduleContext(_ roots: [URL], appModule: String = "App") -> BuildContext {
    BuildContext(
        moduleName: appModule, swiftCompilerPath: "/usr/bin/swiftc", swiftCompilerVersion: "test",
        targetTriple: "arm64-apple-macosx14.0", sdkPath: "/", sdkName: "macosx",
        appBinaryPath: "/unused", moduleSearchPaths: [], extraCompilerFlags: [],
        sourceRoots: roots.map(\.path), bundleIdentifier: "dev.ember.resolver-tests")
}

private func writeModuleFixture(_ text: String, at path: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func severalTargetsInOnePackageAreToldApart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-modules-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Feature"), .target(name: "FeatureUI")])
        """, at: "Package.swift", in: root)
    let feature = try writeModuleFixture("struct Feature {}", at: "Sources/Feature/A.swift", in: root)
    let deep = try writeModuleFixture("struct Deep {}", at: "Sources/Feature/Deep/Nested.swift", in: root)
    let ui = try writeModuleFixture("struct UI {}", at: "Sources/FeatureUI/B.swift", in: root)
    var resolver = ModuleResolver(context: moduleContext([root]), cacheDirectory: root.appendingPathComponent(".cache"))
    #expect(try resolver.resolve(feature).get().module == "Feature")
    #expect(try resolver.resolve(deep).get().manifest?.path == manifest.resolvingSymlinksInPath().path)
    #expect(try resolver.resolve(ui).get().module == "FeatureUI")
}

@Test func aCustomPackageTargetRespectsSourcesAndExclusions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-custom-module-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature-Kit", path: "Components", exclude: ["Logic/Skipped.swift"],
                    sources: ["Logic", "Top.swift"]),
            .target(name: "Other", path: "Components", sources: ["Other.swift"]),
        ])
        """, at: "Package.swift", in: root)
    let logic = try writeModuleFixture("struct Logic {}", at: "Components/Logic/Nested/Logic.swift", in: root)
    let top = try writeModuleFixture("struct Top {}", at: "Components/Top.swift", in: root)
    let excluded = try writeModuleFixture("struct Skipped {}", at: "Components/Logic/Skipped.swift", in: root)
    let unlisted = try writeModuleFixture("struct Unlisted {}", at: "Components/LogicExtra/Unlisted.swift", in: root)
    let other = try writeModuleFixture("struct Other {}", at: "Components/Other.swift", in: root)

    let context = moduleContext([root])
    var resolver = ModuleResolver(context: context, cacheDirectory: root.appendingPathComponent(".cache"))
    #expect(try resolver.resolve(logic).get().module == "Feature_Kit")
    #expect(try resolver.resolve(top).get().packageTarget == "Feature-Kit")
    #expect(try resolver.resolve(other).get().module == "Other")
    #expect(throws: ModuleResolver.Failure.self) { try resolver.resolve(excluded).get() }
    #expect(throws: ModuleResolver.Failure.self) { try resolver.resolve(unlisted).get() }
}

@Test func declaredCustomBuildSourcesUseTheAppModule() throws {
    let root = URL(fileURLWithPath: "/nowhere/CustomApp/Sources")
    var resolver = ModuleResolver(context: moduleContext([root]), cacheDirectory: root)
    let resolution = try resolver.resolve(root.appendingPathComponent("Cart.swift")).get()
    #expect(resolution.module == "App")
    #expect(resolution.manifest == nil)
    #expect(throws: ModuleResolver.Failure.self) {
        try resolver.resolve(root.deletingLastPathComponent().appendingPathComponent("Other.swift")).get()
    }
}

// MARK: - Refusing what cannot be patched

@Test func anEditInAModuleWithNoKeysIsRefusedRatherThanIgnored() async throws {
    // The failure this replaces was silence: an edit in a package that never
    // got implicit dynamic produced no patch, no error, and no reason.
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ember-modules-\(UUID().uuidString)")
    let target = root.appendingPathComponent("Feature/Sources/Feature")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Feature")])
        """, at: "Feature/Package.swift", in: root)

    let subject = target.appendingPathComponent("Greeter.swift")
    try #"struct G { func g() -> String { "old" } }"#
        .write(to: subject, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    _ = try await server.start()
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true", swiftCompilerVersion: "t",
        targetTriple: "arm64-apple-macosx26.0", sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.tests")
    // The app module is patchable; the package is not, which is exactly the
    // state a project is in before the package opts in.
    let coordinator = PatchCoordinator(context: context, server: server,
                                       workDirectory: root.appendingPathComponent("p"),
                                       inventory: ModuleInventory(keys: ["App": 20]))
    try await coordinator.primeBaselines(from: [root])

    try #"struct G { func g() -> String { "new" } }"#
        .write(to: subject, atomically: true, encoding: .utf8)

    guard case .rejected(let error) = await coordinator.handle(change: subject) else {
        Issue.record("an edit in an uninstrumented module was not refused")
        return
    }
    #expect(error.reason.contains("Feature"), "the refusal has to name the module")
    #expect(error.reason.contains("unsafeFlags"), "and say how to fix it")
    #expect(error.reason.contains("App"), "and say what is patchable")
}

@Test func aSwiftUIBoundaryChecksTheBuiltVersionOfAnExcludedFile() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ember-swiftui-shadow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let subject = root.appendingPathComponent("Row.swift")
    let baseline = """
        import SwiftUI
        import EmberSwiftUI
        struct Row: View {
            @ObserveEmber private var ember
            var body: some View { Text("old").emberable() }
        }
        """
    try baseline.write(to: subject, atomically: true, encoding: .utf8)
    let shadow = root.appendingPathComponent("Shadow.swift")
    try "func emberable() {}".write(to: shadow, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    _ = try await server.start()
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/true", swiftCompilerVersion: "t",
        targetTriple: "arm64-apple-macosx26.0", sdkPath: "/", sdkName: "macosx",
        appBinaryPath: root.appendingPathComponent("app").path,
        moduleSearchPaths: [root.path], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-ember.tests",
        excludedSourcePaths: [shadow.path])
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent("p"),
        inventory: ModuleInventory(keys: ["App": 20]))
    let snapshot = try await BuildSourceManifest(context: context).snapshot()
    await coordinator.primeBaselines(from: snapshot)

    // The ignored file can change on disk without changing the running build.
    // Safety checks must keep using the source snapshot that produced it.
    try "func harmless() {}".write(to: shadow, atomically: true, encoding: .utf8)

    try baseline.replacingOccurrences(of: "Text(\"old\")", with: "VStack { Text(\"new\") }")
        .write(to: subject, atomically: true, encoding: .utf8)

    guard case .rejected(let error) = await coordinator.handle(change: subject) else {
        Issue.record("a cross-file emberable declaration was trusted")
        return
    }
    #expect(error.stage == .classify)
    #expect(error.reason.contains("Shadow.swift"))
    #expect(error.reason.contains("rename it and rebuild"))
}

// MARK: - A package's language mode is its own

/// The build settings report the targets of the scheme, and a local package's
/// are not among them -- so the daemon had one `BuildContext`, the
/// application's, and compiled a Swift 6 package's file under the app's Swift 5.
/// Measured: a body using `Task { }` over a non-Sendable capture was accepted
/// into the running process, while the project's own build of that identical
/// file fails with "sending value of non-Sendable type risks causing data
/// races".
@Test func aPackageManifestDecidesItsOwnLanguageMode() throws {
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ember-mode-\(UUID().uuidString)")
    let sources = work.appendingPathComponent("Sources/Feature", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    func manifest(_ text: String) throws {
        try text.write(to: work.appendingPathComponent("Package.swift"),
                       atomically: true, encoding: .utf8)
    }

    try manifest("// swift-tools-version: 6.0\nimport PackageDescription\n")
    guard case .mode(let six) = PackageLanguageMode.read(
        from: work.appendingPathComponent("Package.swift")) else {
        Issue.record("expected a mode"); return
    }
    #expect(six == "6")

    try manifest("// swift-tools-version:5.9\nimport PackageDescription\n")
    guard case .mode(let five) = PackageLanguageMode.read(
        from: work.appendingPathComponent("Package.swift")) else {
        Issue.record("expected a mode"); return
    }
    #expect(five == "5")

    // An explicit setting wins over the tools version.
    try manifest("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "F", targets: [
            .target(name: "F", swiftSettings: [.swiftLanguageMode(.v6)])
        ])
        """)
    guard case .mode(let explicit) = PackageLanguageMode.read(
        from: work.appendingPathComponent("Package.swift")) else {
        Issue.record("expected a mode"); return
    }
    #expect(explicit == "6")

    // Something this cannot evaluate is refused rather than guessed: the wrong
    // mode is not a compile error, it is a body type-checked under rules the
    // developer did not choose.
    try manifest("""
        // swift-tools-version: 5.9
        import PackageDescription
        let mode = SwiftLanguageMode.v6
        let package = Package(name: "F", targets: [
            .target(name: "F", swiftSettings: [.swiftLanguageMode(mode)])
        ])
        """)
    guard case .unknown = PackageLanguageMode.read(
        from: work.appendingPathComponent("Package.swift")) else {
        Issue.record("expected the manifest to be refused"); return
    }
}

@Test func packageTargetCompilerSettingsPreserveConditionsAndUnsafeFlags() throws {
    let dump = #"""
        {
          "toolsVersion":{"_version":"6.0.0"},
          "targets": [{
            "name": "Feature",
            "settings": [
              {"tool":"swift","condition":{"config":"debug","platformNames":["ios"]},"kind":{"define":{"_0":"FEATURE_ONLY"}}},
              {"tool":"swift","condition":{"config":"debug","platformNames":[]},"kind":{"unsafeFlags":{"_0":["-strict-concurrency=complete"]}}},
              {"tool":"swift","condition":{"config":"release","platformNames":[]},"kind":{"define":{"_0":"RELEASE_ONLY"}}},
              {"tool":"linker","condition":null,"kind":{"unsafeFlags":{"_0":["-bad-link-flag"]}}}
            ]
          }]
        }
        """#
    guard case .flags(let flags) = PackageCompilerSettings.decode(
        Data(dump.utf8), module: "Feature", platform: "ios") else {
        Issue.record("the package target settings were not decoded")
        return
    }
    #expect(flags == [
        "-D", "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE", "-D", "FEATURE_ONLY",
        "-strict-concurrency=complete", "-swift-version", "6",
    ])
}

@Test func packageTargetCompilerSettingsUseTheTargetsLanguageMode() throws {
    let dump = #"""
        {
          "toolsVersion":{"_version":"6.0.0"},
          "swiftLanguageVersions":null,
          "targets":[
            {"name":"FeatureA","settings":[
              {"tool":"swift","kind":{"swiftLanguageMode":{"_0":"5"}}}
            ]},
            {"name":"FeatureB","settings":[]}
          ]
        }
        """#
    guard case .flags(let first) = PackageCompilerSettings.decode(
        Data(dump.utf8), module: "FeatureA", platform: "ios"),
          case .flags(let second) = PackageCompilerSettings.decode(
        Data(dump.utf8), module: "FeatureB", platform: "ios") else {
        Issue.record("the target language modes were not decoded")
        return
    }
    #expect(first == [
        "-D", "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE",
        "-enable-bare-slash-regex", "-swift-version", "5",
    ])
    #expect(second == [
        "-D", "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE", "-swift-version", "6",
    ])
}

@Test func packageTargetCompilerSettingsAreReadFromTheEvaluatedManifest() throws {
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ember-package-settings-\(UUID().uuidString)", isDirectory: true)
    let sources = work.appendingPathComponent("Sources/Feature", isDirectory: true)
    let resources = work.appendingPathComponent("Sources/Feature/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature", resources: [.process("Resources")], swiftSettings: [
                .define("ON_IOS", .when(platforms: [.iOS], configuration: .debug)),
                .unsafeFlags(["-strict-concurrency=complete"]),
                .swiftLanguageMode(.v5),
            ])
        ])
        """.write(
            to: work.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8)
    try "public func value() {}\n".write(
        to: sources.appendingPathComponent("Feature.swift"),
        atomically: true, encoding: .utf8)
    try "fixture\n".write(
        to: resources.appendingPathComponent("value.txt"),
        atomically: true, encoding: .utf8)

    guard case .flags(let flags) = PackageCompilerSettings.read(
        module: "Feature", manifest: work.appendingPathComponent("Package.swift"),
        swiftCompilerPath: "/usr/bin/swiftc", sdkName: "iphoneos",
        cacheDirectory: work.appendingPathComponent("cache", isDirectory: true)) else {
        Issue.record("the evaluated package settings were unavailable")
        return
    }
    #expect(flags == [
        "-D", "SWIFT_PACKAGE", "-D", "DEBUG",
        "-D", "SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE", "-D", "ON_IOS",
        "-strict-concurrency=complete", "-enable-bare-slash-regex", "-swift-version", "5",
        "-package-name", work.lastPathComponent.lowercased().replacingOccurrences(of: "-", with: "_"),
    ])
}

@Test func swiftFivePackageDefaultsEnableBareSlashRegex() throws {
    let dump = #"""
        {
          "toolsVersion":{"_version":"5.9.0"},
          "targets":[{"name":"Feature","settings":[]}]
        }
        """#
    guard case .flags(let flags) = PackageCompilerSettings.decode(
        Data(dump.utf8), module: "Feature", platform: "ios") else {
        Issue.record("the package defaults were not decoded")
        return
    }
    #expect(flags == [
        "-D", "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE",
        "-enable-bare-slash-regex", "-swift-version", "5",
    ])

    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-bare-regex-\(UUID().uuidString).swift")
    defer { try? FileManager.default.removeItem(at: source) }
    try "let expression = /ember/\n".write(
        to: source, atomically: true, encoding: .utf8)
    let result = try Subprocess.runSeparated(
        "/usr/bin/swiftc", arguments: flags + ["-typecheck", source.path])
    #expect(result.exitCode == 0, Comment(rawValue: result.standardError))
}

@Test func unknownPackageTargetCompilerSettingsFailClosed() {
    let dump = #"""
        {"targets":[{"name":"Feature","settings":[
          {"tool":"swift","condition":null,"kind":{"futureSetting":{"_0":"value"}}}
        ]}]}
        """#
    guard case .unknown(let reason) = PackageCompilerSettings.decode(
        Data(dump.utf8), module: "Feature", platform: "ios") else {
        Issue.record("an unknown compiler setting was accepted")
        return
    }
    #expect(reason.contains("futureSetting"))
}

@Test func aTransientPackageSettingsFailureIsRetried() async throws {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-package-settings-retry-\(UUID().uuidString)")
    let sources = work.appendingPathComponent("Sources/Feature", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let manifest = work.appendingPathComponent("Package.swift")
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature", swiftSettings: [)
        ])
        """.write(to: manifest, atomically: true, encoding: .utf8)
    let source = sources.appendingPathComponent("Subject.swift")
    try "public func value() -> Int { 1 }".write(
        to: source, atomically: true, encoding: .utf8)

    let server = try IPCServer()
    defer { server.stop() }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/swiftc",
        swiftCompilerVersion: "test", targetTriple: "arm64-apple-macosx26.0",
        sdkPath: "/", sdkName: "macosx",
        appBinaryPath: work.appendingPathComponent("app").path,
        moduleSearchPaths: [work.path], extraCompilerFlags: [],
        sourceRoots: [sources.path], bundleIdentifier: "dev.swift-ember.settings-retry-tests")
    let coordinator = PatchCoordinator(
        context: context, server: server,
        workDirectory: work.appendingPathComponent("patches"),
        inventory: ModuleInventory(keys: ["Feature": 1]))
    try await coordinator.primeBaselines(from: [sources])
    try "public func value() -> Int { 2 }".write(
        to: source, atomically: true, encoding: .utf8)

    guard case .rejected(let first) = await coordinator.handle(change: source) else {
        Issue.record("the malformed manifest was not refused")
        return
    }
    #expect(first.stage == .classify)

    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature", swiftSettings: [.define("REPAIRED")])
        ])
        """.write(to: manifest, atomically: true, encoding: .utf8)

    guard case .rejected(let second) = await coordinator.handle(change: source) else {
        Issue.record("the repaired manifest unexpectedly loaded without a runtime")
        return
    }
    #expect(second.stage == .compile,
            "the first settings failure was cached instead of reevaluating the manifest")
}

/// Custom build sources can coexist with an unrelated package in the repository.
@Test func aManifestAboveAnAppIsNotThatAppsManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-layout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Feature")])
        """, at: "Package.swift", in: root)
    let app = try writeModuleFixture("struct Cart {}", at: "examples/Demo/Sources/Cart.swift", in: root)
    let feature = try writeModuleFixture("struct Greeter {}", at: "Sources/Feature/Greeter.swift", in: root)
    let context = moduleContext([app.deletingLastPathComponent(), feature.deletingLastPathComponent()],
                                appModule: "Demo")
    var resolver = ModuleResolver(context: context, cacheDirectory: root.appendingPathComponent(".cache"))
    let resolution = try resolver.resolve(app).get()
    #expect(resolution.module == "Demo")
    #expect(resolution.manifest == nil)
    let inPackage = try resolver.resolve(feature).get()
    #expect(inPackage.module == "Feature")
    #expect(inPackage.manifest != nil)
}

@Test func watchRejectsChangesToAnUnresolvedXcodeSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-unresolved-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeModuleFixture("func value() -> Int { 1 }", at: "Unknown.swift", in: root)
    var context = moduleContext([root])
    context.xcodeSourceTargets = []
    let server = try IPCServer()
    defer { server.stop() }
    let coordinator = PatchCoordinator(context: context, server: server, workDirectory: root)
    let startup = try await coordinator.primeBaselines(from: [root])
    #expect(startup.diagnostics.count == 1)
    try "func value() -> Int { 2 }".write(to: source, atomically: true, encoding: .utf8)
    guard case .rejected(let error) = await coordinator.handle(change: source) else {
        Issue.record("the unresolved file was not diagnosed")
        return
    }
    #expect(error.stage == .classify)
    #expect(error.reason.contains(source.path))
    #expect(error.reason.contains("sourceModules"))
}

@Test func aNewUnbuiltSourceRequestsARebuildOnEverySave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-unbuilt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var context = moduleContext([root])
    context.xcodeSourceTargets = []
    let server = try IPCServer()
    defer { server.stop() }
    let coordinator = PatchCoordinator(context: context, server: server, workDirectory: root)
    try await coordinator.primeBaselines(from: [root])
    let source = try writeModuleFixture("func value() -> Int { 1 }", at: "New.swift", in: root)
    for added: Set<URL> in [[source], []] {
        guard case .rejected(let error) = await coordinator.handle(changes: [source], added: added) else {
            Issue.record("a source missing from the current build was accepted")
            return
        }
        #expect(error.stage == .classify)
        #expect(error.recovery == .rebuild)
        #expect(error.reason.contains("missing from the current build"))
        #expect(error.reason.contains("sourceModules") == false)
    }
}

@Test func watchPrimesPackageMembershipAndCompilerSettingsBeforeEditing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-warm-package-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeModuleFixture("func value() -> Int { 1 }", at: "Inputs/Feature.swift", in: root)
    _ = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature", path: "Inputs", swiftSettings: [.define("TEST_FLAG")])
        ])
        """, at: "Package.swift", in: root)
    let swift = try writeModuleFixture(#"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$(dirname "$0")/calls.log"
        exec /usr/bin/swift "$@"
        """#, at: ".tools/swift", in: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    let compiler = swift.deletingLastPathComponent().appendingPathComponent("swiftc")
    try FileManager.default.createSymbolicLink(
        at: compiler, withDestinationURL: URL(fileURLWithPath: "/usr/bin/false"))
    let log = swift.deletingLastPathComponent().appendingPathComponent("calls.log")

    var context = moduleContext([source.deletingLastPathComponent()])
    context.swiftCompilerPath = compiler.path
    let server = try IPCServer()
    defer { server.stop() }
    let coordinator = PatchCoordinator(
        context: context, server: server, workDirectory: root.appendingPathComponent(".patches"),
        inventory: ModuleInventory(keys: ["Feature": 1]))
    let startup = try await coordinator.primeBaselines(from: [source.deletingLastPathComponent()])
    #expect(startup.diagnostics.isEmpty)
    let startupCalls = try String(contentsOf: log, encoding: .utf8)
    #expect(startupCalls.split(separator: "\n").count == 2)
    #expect(startupCalls.contains("describe --type json"))
    #expect(startupCalls.contains("dump-package"))

    try "func value() -> Int { 2 }".write(to: source, atomically: true, encoding: .utf8)
    guard case .rejected(let error) = await coordinator.handle(change: source) else {
        Issue.record("the compiler fixture should reject the patch")
        return
    }
    #expect(error.stage == .compile)
    #expect(try String(contentsOf: log, encoding: .utf8) == startupCalls)
}

@Test func packageTestEditsAndAdditionsDoNotReachThePatchPipeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-test-source-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let initialTest = try writeModuleFixture("struct Test {}", at: "Checks/Test.swift", in: root)
    let library = try writeModuleFixture("struct Product {}", at: "UI/Feature.swift", in: root)
    _ = try writeModuleFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Feature", path: "UI"),
            .testTarget(name: "Checks", dependencies: ["Feature"], path: "Checks")
        ])
        """, at: "Package.swift", in: root)
    let roots = [initialTest.deletingLastPathComponent(), library.deletingLastPathComponent()]
    let server = try IPCServer()
    defer { server.stop() }
    let coordinator = PatchCoordinator(context: moduleContext(roots), server: server, workDirectory: root)
    let startup = try await coordinator.primeBaselines(from: roots)
    #expect(startup.testSources.count == 1)
    #expect(startup.diagnostics.isEmpty)
    #expect(!(await coordinator.hasBaseline(for: initialTest)))

    let newTest = try writeModuleFixture("struct AddedTest {}", at: "Checks/Added.swift", in: root)
    guard case .ignored = await coordinator.handle(changes: [initialTest, newTest], added: [newTest]) else {
        Issue.record("test files reached the patch pipeline")
        return
    }
}
