import Foundation
import Testing
import SpliceCore
@testable import SpliceCLI
@testable import SpliceDaemon

/// Argument parsing had no tests. It is the first thing a user touches, and a
/// combination that slips through validation produces a confusing failure much
/// later, from xcodebuild or from a missing file.

private func parse(_ arguments: String...) throws -> Options {
    try Options.parse(arguments)
}

@Test func aBareCommandParses() throws {
    #expect(try parse("watch").command == .watch)
    #expect(try parse("doctor").command == .doctor)
    #expect(try parse("status").command == .status)
}

@Test func flagsMayComeBeforeOrAfterTheCommand() throws {
    let before = try parse("--scheme", "App", "--project", "App.xcodeproj", "watch")
    let after = try parse("watch", "--project", "App.xcodeproj", "--scheme", "App")
    #expect(before.command == after.command)
    #expect(before.project == after.project)
    #expect(before.scheme == after.scheme)
}

@Test func aFlagValueThatLooksLikeACommandIsStillAValue() throws {
    // `--scheme watch` must not be read as the watch command.
    let options = try parse("doctor", "--project", "App.xcodeproj", "--scheme", "watch")
    #expect(options.command == .doctor)
    #expect(options.scheme == "watch")
}

@Test func aSecondCommandIsRejected() {
    #expect(throws: Options.ParseError.self) { _ = try parse("watch", "doctor") }
}

@Test func anUnknownArgumentIsRejected() {
    #expect(throws: Options.ParseError.self) { _ = try parse("watch", "--nope") }
}

@Test func aMissingFlagValueIsRejected() {
    #expect(throws: Options.ParseError.self) { _ = try parse("watch", "--scheme") }
}

@Test func noCommandIsUsage() {
    #expect(throws: Options.ParseError.self) { _ = try parse("--project", "App.xcodeproj") }
}

@Test func aProjectWithoutASchemeIsRejected() {
    // xcodebuild would fail later and less clearly.
    #expect(throws: Options.ParseError.self) { _ = try parse("watch", "--project", "App.xcodeproj") }
}

@Test func aProjectAndAWorkspaceTogetherAreRejected() {
    #expect(throws: Options.ParseError.self) {
        _ = try parse("watch", "--project", "A.xcodeproj", "--workspace", "B.xcworkspace", "--scheme", "S")
    }
}

@Test func aRepeatedFlagTakesTheLastValue() throws {
    let options = try parse("watch", "--project", "A.xcodeproj", "--project", "B.xcodeproj", "--scheme", "S")
    #expect(options.project == "B.xcodeproj")
}

@Test func sourcesSplitOnCommasAndTrim() throws {
    let options = try parse("watch", "--sources", "a/Sources, b/Sources ,c")
    #expect(options.sourceRoots == ["a/Sources", "b/Sources", "c"])
}

@Test func aSchemeWithoutAContainerIsHarmless() throws {
    // Nothing to resolve, so the manifest path is used and --scheme is ignored.
    let options = try parse("watch", "--scheme", "App")
    #expect(try options.resolveProject() == nil)
}

// MARK: - Link target

@Test func theDebugDylibIsUsedOnlyWhenTheBuildSaysSo() {
    // Never inferred from the file being there: a dylib from an earlier build
    // outlives the setting, and linking against one the process is not running
    // makes dlopen pull a second copy of the app module into the live process.
    var context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/swiftc", swiftCompilerVersion: "6.4",
        targetTriple: "arm64-apple-ios18.0-simulator", sdkPath: "/sdk", sdkName: "iphonesimulator",
        appBinaryPath: "/tmp/App.app/App", moduleSearchPaths: [], extraCompilerFlags: [],
        sourceRoots: [], bundleIdentifier: "dev.example.App")

    #expect(context.linkTarget == "/tmp/App.app/App")

    context.debugDylibPath = "/tmp/App.app/App.debug.dylib"
    #expect(context.linkTarget == "/tmp/App.app/App.debug.dylib")
}

@Test func aMissingDeploymentTargetUsesTheSupportedIOSFloor() throws {
    let common = ["ARCHS": "arm64"]
    #expect(try XcodeProject.targetTriple(from: common.merging(
        ["PLATFORM_NAME": "iphonesimulator"], uniquingKeysWith: { _, new in new }))
        == "arm64-apple-ios16.0-simulator")
    #expect(try XcodeProject.targetTriple(from: common.merging(
        ["PLATFORM_NAME": "iphoneos"], uniquingKeysWith: { _, new in new }))
        == "arm64-apple-ios16.0")
}

@Test func aReportedDeploymentTargetStillWinsOverTheFloor() throws {
    #expect(try XcodeProject.targetTriple(from: [
        "ARCHS": "arm64",
        "PLATFORM_NAME": "iphonesimulator",
        "IPHONEOS_DEPLOYMENT_TARGET": "18.2",
    ]) == "arm64-apple-ios18.2-simulator")
}

// MARK: - Search paths

// Xcode reports these as one space-separated string with quoted entries, and a
// parity split on the quote character broke whenever the first entry was
// quoted. swiftc ignores a -F that does not exist, so the damage showed up as
// "no such module" rather than as anything pointing here.

@Test func searchPathsHandleQuotingAndRecursion() {
    #expect(XcodeProject.parseSearchPaths(nil) == [])
    #expect(XcodeProject.parseSearchPaths("") == [])
    #expect(XcodeProject.parseSearchPaths("/a/b") == ["/a/b"])
    #expect(XcodeProject.parseSearchPaths("/a/b /c/d") == ["/a/b", "/c/d"])

    // Leading quoted entry: the case parity got wrong.
    #expect(XcodeProject.parseSearchPaths("\"/Users/me/My App/Frameworks\" /other")
            == ["/Users/me/My App/Frameworks", "/other"])
    #expect(XcodeProject.parseSearchPaths("\"/My App/A\" \"/My App/B\"")
            == ["/My App/A", "/My App/B"])
    #expect(XcodeProject.parseSearchPaths("/a/b \"/Users/me/My App/Frameworks\"")
            == ["/a/b", "/Users/me/My App/Frameworks"])

    // `/**` means recursive to Xcode and nothing to swiftc.
    #expect(XcodeProject.parseSearchPaths("/a/b/**") == ["/a/b"])
}

// MARK: - Build context

@Test func aManifestMissingSourceRootsIsRefused() {
    // Tolerating this produced a daemon that watched nothing and said nothing.
    let json = """
    {"moduleName":"A","swiftCompilerPath":"/x","swiftCompilerVersion":"v",
     "targetTriple":"t","sdkPath":"/s","sdkName":"n","appBinaryPath":"/b",
     "bundleIdentifier":"id","moduleSearchPaths":[],"extraCompilerFlags":[]}
    """
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(BuildContext.self, from: Data(json.utf8))
    }
}

@Test func aManifestMissingOnlyFrameworkSearchPathsStillLoads() {
    // The one field added after the format was in use.
    let json = """
    {"moduleName":"A","swiftCompilerPath":"/x","swiftCompilerVersion":"v",
     "targetTriple":"t","sdkPath":"/s","sdkName":"n","appBinaryPath":"/b",
     "bundleIdentifier":"id","moduleSearchPaths":["/m"],"extraCompilerFlags":[],
     "sourceRoots":["/r"]}
    """
    let context = try! JSONDecoder().decode(BuildContext.self, from: Data(json.utf8))
    #expect(context.frameworkSearchPaths.isEmpty)
    #expect(context.sourceRoots == ["/r"])
}

@Test func aBuildContextRoundTrips() throws {
    let original = BuildContext(
        moduleName: "A", swiftCompilerPath: "/x", swiftCompilerVersion: "v",
        targetTriple: "t", sdkPath: "/s", sdkName: "n", appBinaryPath: "/b",
        moduleSearchPaths: ["/m"], extraCompilerFlags: ["-D", "X"],
        sourceRoots: ["/r"], bundleIdentifier: "id",
        debugDylibPath: "/b.debug.dylib", frameworkSearchPaths: ["/f"])
    let decoded = try JSONDecoder().decode(
        BuildContext.self, from: try JSONEncoder().encode(original))
    #expect(decoded.identity == original.identity)
    #expect(decoded.debugDylibPath == original.debugDylibPath)
    #expect(decoded.frameworkSearchPaths == original.frameworkSearchPaths)
    #expect(decoded.linkTarget == original.linkTarget)
}

// MARK: - Diagnostics that are really build settings

/// The compiler says "module was not compiled for private import" and stops.
/// Left alone, a project missing the setting is shown that against generated
/// source it never wrote, at a line it cannot open.
@Test func aMissingPrivateImportIsExplainedAsASetting() {
    let output = """
    /tmp/.splice/Patch_001.swift:3:54: error: module 'App' was not compiled for private import
    """
    let explanation = PatchCompiler.explain(output)
    #expect(explanation?.contains("-enable-private-imports") == true)
    #expect(explanation?.contains("unsafeFlags") == true)
    #expect(explanation?.contains("rebuild") == true)
}

@Test func anOrdinaryCompileErrorIsLeftAlone() {
    #expect(PatchCompiler.explain("error: cannot find 'x' in scope") == nil)
}

/// Reading one pipe to EOF and then the other deadlocks as soon as the child
/// fills the one nobody is draining. Measured on the shape this call actually
/// has -- `xcodebuild -showBuildSettings`, which writes to stderr -- 64 KB came
/// back and 300 KB hung forever, so `watch` never finished starting and printed
/// nothing to say why.
///
/// Raced against a deadline rather than simply called: a regression here would
/// otherwise hang the whole suite with no output, which is the same failure it
/// is testing for.
@Test func aChildThatFillsStderrDoesNotDeadlockTheReader() async throws {
    let work = Task.detached {
        try Subprocess.runSeparated(
            "/usr/bin/perl",
            arguments: ["-e", "print STDERR 'x' x 300000; print STDOUT 'done'; exit 0"])
    }

    let finished = await withTaskGroup(of: Subprocess.SeparatedResult?.self) { group in
        group.addTask { try? await work.value }
        group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }

    guard let finished else {
        Issue.record("runSeparated did not return within 20 seconds")
        return
    }
    #expect(finished.exitCode == 0)
    #expect(finished.standardOutput == "done")
    #expect(finished.standardError.count == 300_000)
}
