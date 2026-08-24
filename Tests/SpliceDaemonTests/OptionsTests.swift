import Testing
import SpliceCore
@testable import SpliceCLI

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
