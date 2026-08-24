import Foundation
import Testing
import SpliceCore
@testable import SpliceDaemon

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

private func resolve(_ path: String, appModule: String = "App") -> String {
    ModuleResolver(appModule: appModule).module(for: URL(fileURLWithPath: path))
}

@Test func aFileInAPackageTargetResolvesToThatTarget() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-modules-\(UUID().uuidString)")
    let target = root.appendingPathComponent("Feature/Sources/Feature")
    let nested = root.appendingPathComponent("Feature/Sources/Feature/Deep/Deeper")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Feature/Package.swift"))

    #expect(resolve(target.appendingPathComponent("Greeter.swift").path) == "Feature")
    // Depth inside the target does not change the answer.
    #expect(resolve(nested.appendingPathComponent("Helper.swift").path) == "Feature")
}

@Test func severalTargetsInOnePackageAreToldApart() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-modules-\(UUID().uuidString)")
    for target in ["Feature", "FeatureUI"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Kit/Sources/\(target)"), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("Kit/Package.swift"))

    #expect(resolve(root.appendingPathComponent("Kit/Sources/Feature/A.swift").path) == "Feature")
    #expect(resolve(root.appendingPathComponent("Kit/Sources/FeatureUI/B.swift").path) == "FeatureUI")
}

@Test func aFileOutsideAnyPackageIsTheAppModule() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-modules-\(UUID().uuidString)/Sources")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(resolve(root.appendingPathComponent("Cart.swift").path, appModule: "XcodeApp") == "XcodeApp")
}

@Test func aFileInAPackageButOutsideSourcesIsNotATarget() throws {
    // Package.swift itself, or a Tests directory: not a target's source, and
    // guessing a module name from it would produce a patch that imports
    // something that does not exist.
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-modules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Kit/Tests/KitTests"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Kit/Package.swift"))

    #expect(resolve(root.appendingPathComponent("Kit/Tests/KitTests/T.swift").path,
                    appModule: "App") == "App")
}

// MARK: - Refusing what cannot be patched

@Test func anEditInAModuleWithNoKeysIsRefusedRatherThanIgnored() async throws {
    // The failure this replaces was silence: an edit in a package that never
    // got implicit dynamic produced no patch, no error, and no reason.
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-modules-\(UUID().uuidString)")
    let target = root.appendingPathComponent("Feature/Sources/Feature")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Feature/Package.swift"))

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
        sourceRoots: [root.path], bundleIdentifier: "dev.swift-splice.tests")
    // The app module is patchable; the package is not, which is exactly the
    // state a project is in before the package opts in.
    let coordinator = PatchCoordinator(context: context, server: server,
                                       workDirectory: root.appendingPathComponent("p"),
                                       inventory: ModuleInventory(keys: ["App": 20]))
    await coordinator.primeBaselines(from: [root])

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
