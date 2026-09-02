import Foundation
import Testing
import EmberCore
@testable import EmberCLI
@testable import EmberDaemon

/// Argument parsing had no tests. It is the first thing a user touches, and a
/// combination that slips through validation produces a confusing failure much
/// later, from xcodebuild or from a missing file.

private func parse(_ arguments: String...) throws -> Options {
    try Options.parse(arguments)
}

private func withConfiguration(
    _ contents: String,
    in nestedDirectory: Bool = false,
    operation: (URL, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-options-\(UUID().uuidString)", isDirectory: true)
    let current = nestedDirectory ? root.appendingPathComponent("Develop", isDirectory: true) : root
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(contents.utf8).write(to: root.appendingPathComponent(".swift-ember.json"))
    try operation(root, current)
}

@Test func aBareCommandParses() throws {
    #expect(try parse("watch").command == .watch)
    #expect(try parse("start").command == .start)
    #expect(try parse("stop").command == .stop)
    #expect(try parse("doctor").command == .doctor)
    #expect(try parse("status").command == .status)
}

@Test func xcodeNeedsAStartOrStopAction() throws {
    #expect(throws: Options.ParseError.self) { _ = try parse("xcode") }
    #expect(throws: Options.ParseError.self) { _ = try parse("xcode", "watch") }
}

@Test func xcodeActionsReadTheNearestProjectConfiguration() throws {
    try withConfiguration(#"""
        {
          "workspace": "Bookshelf.xcworkspace",
          "scheme": "Client Develop",
          "sources": ["Presentation/Sources", "Client/Sources"],
          "exclude": ["Client/Sources/Generated", "Vendor/Legacy.swift"]
        }
        """#, in: true) { root, current in
        let options = try Options.parse(
            ["xcode", "start"], environment: ["SRCROOT": current.path], currentDirectory: current)
        #expect(options.command == .xcode)
        #expect(options.xcodeAction == .start)
        #expect(options.workspace == root.appendingPathComponent("Bookshelf.xcworkspace").path)
        #expect(options.scheme == "Client Develop")
        #expect(options.sourceRoots == [
            root.appendingPathComponent("Presentation/Sources").path,
            root.appendingPathComponent("Client/Sources").path,
        ])
        #expect(options.excludedSourcePaths == [
            root.appendingPathComponent("Client/Sources/Generated").path,
            root.appendingPathComponent("Vendor/Legacy.swift").path,
        ])
        #expect(options.configPath == root.appendingPathComponent(".swift-ember.json").path)
    }
}

@Test func explicitArgumentsOverrideProjectConfigurationDefaults() throws {
    try withConfiguration(#"""
        {
          "workspace": "Configured.xcworkspace",
          "scheme": "Configured",
          "configuration": "Debug",
          "sources": ["ConfiguredSources"],
          "exclude": ["ConfiguredSources/Generated"]
        }
        """#) { _, current in
        let options = try Options.parse([
            "watch", "--config", current.appendingPathComponent(".swift-ember.json").path,
            "--project", "Explicit.xcodeproj", "--scheme", "Explicit",
            "--configuration", "Profile", "--sources", "A,B",
            "--exclude", "A/Fixtures,B/Generated.swift",
        ], environment: [:], currentDirectory: current)
        #expect(options.project == "Explicit.xcodeproj")
        #expect(options.workspace == nil)
        #expect(options.scheme == "Explicit")
        #expect(options.configuration == "Profile")
        #expect(options.sourceRoots == ["A", "B"])
        #expect(options.excludedSourcePaths == ["A/Fixtures", "B/Generated.swift"])
    }
}

@Test func explicitContextBypassesAnAutomaticallyDiscoveredXcodeConfiguration() throws {
    try withConfiguration(#"{"workspace":"Configured.xcworkspace","scheme":"Configured"}"#) {
        _, current in
        let options = try Options.parse(
            ["status", "--context", "custom-context.json"],
            environment: [:], currentDirectory: current)
        #expect(options.contextPath == "custom-context.json")
        #expect(options.project == nil)
        #expect(options.workspace == nil)
        #expect(options.scheme == nil)
        #expect(options.configPath == nil)
    }
}

@Test func explicitContextAndXcodeContainerAreMutuallyExclusive() {
    #expect(throws: Options.ParseError.self) {
        _ = try parse(
            "status", "--context", "context.json",
            "--project", "App.xcodeproj", "--scheme", "App")
    }
}

@Test func anExplicitContainerDoesNotBorrowAnotherContainersScheme() throws {
    try withConfiguration(#"{"workspace":"Configured.xcworkspace","scheme":"Configured"}"#) {
        _, current in
        #expect(throws: Options.ParseError.self) {
            _ = try Options.parse(
                ["status", "--project", "Explicit.xcodeproj"],
                environment: [:], currentDirectory: current)
        }
    }
}

@Test func aCompleteExplicitTargetBypassesMalformedAutomaticConfiguration() throws {
    try withConfiguration("not json") { _, current in
        let options = try Options.parse([
            "stop", "--workspace", "Explicit.xcworkspace", "--scheme", "Explicit",
        ], environment: [:], currentDirectory: current)
        #expect(options.workspace == "Explicit.xcworkspace")
        #expect(options.scheme == "Explicit")
        #expect(options.configPath == nil)
    }
}

@Test func noConfigProvidesAnExplicitConfigurationEscapeHatch() throws {
    try withConfiguration("not json") { _, current in
        let options = try Options.parse(
            ["status", "--no-config", "--context", "context.json"],
            environment: [:], currentDirectory: current)
        #expect(options.ignoresProjectConfiguration)
        #expect(options.contextPath == "context.json")
    }
}

@Test func configAndNoConfigAreMutuallyExclusive() {
    #expect(throws: Options.ParseError.self) {
        _ = try parse("status", "--config", "config.json", "--no-config")
    }
}

@Test func xcodeCanUseItsContainerEnvironmentWithoutAConfigurationFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-no-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = root.appendingPathComponent("App.xcworkspace").path
    let options = try Options.parse(
        ["xcode", "stop", "--scheme", "App"],
        environment: ["WORKSPACE_PATH": workspace], currentDirectory: root)
    #expect(options.workspace == workspace)
    #expect(options.xcodeAction == .stop)
}

@Test func xcodeSeparatesPhysicalAndSimulatorIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-device-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("App.xcodeproj").path
    // A physical CoreDevice UDID is not an RFC UUID. Requiring UUID syntax
    // silently selected the Simulator transport for real iPhones.
    let identifier = "00008120-001E1C66369B401E"

    let physical = try Options.parse(
        ["xcode", "start", "--scheme", "App"], environment: [
            "PROJECT_FILE_PATH": project,
            "PLATFORM_NAME": "iphoneos",
            "TARGET_DEVICE_IDENTIFIER": identifier,
        ], currentDirectory: root)
    #expect(physical.device == identifier)

    let simulator = try Options.parse(
        ["xcode", "start", "--scheme", "App"], environment: [
            "PROJECT_FILE_PATH": project,
            "PLATFORM_NAME": "iphonesimulator",
            "TARGET_DEVICE_IDENTIFIER": identifier,
        ], currentDirectory: root)
    #expect(simulator.device == nil)
    #expect(simulator.simulator == identifier)

    let placeholder = try Options.parse(
        ["xcode", "start", "--scheme", "App"], environment: [
            "PROJECT_FILE_PATH": project,
            "PLATFORM_NAME": "iphoneos",
            "TARGET_DEVICE_IDENTIFIER": "dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder",
        ], currentDirectory: root)
    #expect(placeholder.device == nil)

    let generic = try Options.parse(
        ["xcode", "start", "--scheme", "App"], environment: [
            "PROJECT_FILE_PATH": project,
            "PLATFORM_NAME": "iphoneos",
            "TARGET_DEVICE_IDENTIFIER": "generic/platform=iOS",
        ], currentDirectory: root)
    #expect(generic.device == nil)
}

@Test func xcodeActionsApplyOnlyToTheirConfiguredBuild() throws {
    let options = Options(command: .xcode, xcodeAction: .start, configuration: "Debug")
    #expect(options.appliesToXcodeConfiguration(environment: [:]))
    #expect(options.appliesToXcodeConfiguration(environment: ["CONFIGURATION": "Debug"]))
    #expect(!options.appliesToXcodeConfiguration(environment: ["CONFIGURATION": "Release"]))
}

@Test func malformedProjectConfigurationIsReportedByTheParser() throws {
    try withConfiguration(#"{"project":"App.xcodeproj","workspace":"App.xcworkspace","scheme":"App"}"#) {
        _, current in
        #expect(throws: Options.ParseError.self) {
            _ = try Options.parse(["watch"], environment: [:], currentDirectory: current)
        }
    }
}

@Test func unknownProjectConfigurationKeysAreRejected() throws {
    try withConfiguration(#"{"workspace":"App.xcworkspace","scheme":"App","sourceRoots":["Sources"]}"#) {
        _, current in
        do {
            _ = try Options.parse(["watch"], environment: [:], currentDirectory: current)
            Issue.record("the unknown sourceRoots key should be rejected")
        } catch Options.ParseError.configuration(let reason) {
            #expect(reason.contains("unknown keys: sourceRoots"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Test func emptyProjectConfigurationExclusionsAreRejected() throws {
    try withConfiguration(#"{"exclude":["  "]}"#) { _, current in
        do {
            _ = try Options.parse(["watch"], environment: [:], currentDirectory: current)
            Issue.record("an empty exclude path should be rejected")
        } catch Options.ParseError.configuration(let reason) {
            #expect(reason.contains("empty exclude path"))
            #expect(reason.contains("use an empty array"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
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

@Test func helpIsNotAnInvalidInvocation() {
    for flag in ["-h", "--help"] {
        do {
            _ = try parse(flag)
            Issue.record("\(flag) should stop parsing")
        } catch Options.ParseError.help {
            // The executable prints usage and exits successfully for this case.
        } catch {
            Issue.record("unexpected error for \(flag): \(error)")
        }
    }
}

@Test func versionIsNotAnInvalidInvocation() {
    for flag in ["-V", "--version"] {
        do {
            _ = try parse(flag)
            Issue.record("\(flag) should stop parsing")
        } catch Options.ParseError.version {
            // The executable prints the version and exits successfully.
        } catch {
            Issue.record("unexpected error for \(flag): \(error)")
        }
    }
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

@Test func exclusionsSplitOnCommasAndTrim() throws {
    let options = try parse("watch", "--exclude", "a/Tests, b/Generated ,c.swift")
    #expect(options.excludedSourcePaths == ["a/Tests", "b/Generated", "c.swift"])
}

@Test func explicitExclusionsOverrideAnEmittedContext() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let contextURL = root.appendingPathComponent("context.json")
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/swiftc", swiftCompilerVersion: "6",
        targetTriple: "arm64-apple-ios16.0-simulator", sdkPath: "/sdk",
        sdkName: "iphonesimulator", appBinaryPath: "/App", moduleSearchPaths: [],
        extraCompilerFlags: [], sourceRoots: ["/Sources"], bundleIdentifier: "id",
        excludedSourcePaths: ["/Sources/Generated"])
    try context.write(to: contextURL)

    let options = try Options.parse([
        "status", "--context", contextURL.path, "--exclude", "/Sources/Fixtures",
    ], environment: [:], currentDirectory: root)
    let resolved = try options.buildContext(project: nil)

    #expect(resolved.excludedSourcePaths == ["/Sources/Fixtures"])
}

@Test func physicalDeviceOptionsParse() throws {
    let options = try parse("watch", "--project", "App.xcodeproj", "--scheme", "App",
                            "--device", "DEVICE-ID", "--signing-identity", "SIGNING-SHA")
    #expect(options.device == "DEVICE-ID")
    #expect(options.signingIdentity == "SIGNING-SHA")
}

@Test func simulatorOptionsParseAndCannotConflictWithAPhysicalDevice() throws {
    let options = try parse("watch", "--project", "App.xcodeproj", "--scheme", "App",
                            "--simulator", "SIMULATOR-ID")
    #expect(options.simulator == "SIMULATOR-ID")
    #expect(options.device == nil)

    #expect(throws: Options.ParseError.self) {
        _ = try parse("watch", "--project", "App.xcodeproj", "--scheme", "App",
                      "--device", "DEVICE-ID", "--simulator", "SIMULATOR-ID")
    }
}

@Test func explicitSimulatorOverridesXcodesDestinationEnvironment() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-explicit-simulator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let options = try Options.parse(
        ["xcode", "start", "--scheme", "App", "--simulator", "EXPLICIT"],
        environment: [
            "PROJECT_FILE_PATH": root.appendingPathComponent("App.xcodeproj").path,
            "PLATFORM_NAME": "iphonesimulator",
            "TARGET_DEVICE_IDENTIFIER": "XCODE-SELECTED",
        ], currentDirectory: root)
    #expect(options.simulator == "EXPLICIT")
    #expect(options.device == nil)
}

@Test func startupTimeoutMustBePositive() throws {
    #expect(try parse("start", "--startup-timeout", "90").startupTimeout == 90)
    #expect(try parse("start").startupTimeout == 60)
    #expect(throws: Options.ParseError.self) {
        _ = try parse("start", "--startup-timeout", "0")
    }
    #expect(throws: Options.ParseError.self) {
        _ = try parse("start", "--startup-timeout", "later")
    }
    #expect(throws: Options.ParseError.self) {
        _ = try parse("start", "--startup-timeout", "inf")
    }
}

@Test func aPhysicalDeviceSelectsAnXcodeDeviceDestination() {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App",
                               deviceIdentifier: "DEVICE-ID")
    #expect(project.destination == "id=DEVICE-ID")
    #expect(project.deviceIdentifier == "DEVICE-ID")
    #expect(project.simulatorIdentifier == nil)
}

@Test func aSimulatorSelectsItsExactXcodeDestination() {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App",
                               simulatorIdentifier: "SIMULATOR-ID")
    #expect(project.destination == "id=SIMULATOR-ID")
    #expect(project.deviceIdentifier == nil)
    #expect(project.simulatorIdentifier == "SIMULATOR-ID")
}

@Test func simulatorContainerUsesTheSelectedDeviceInsteadOfBooted() {
    #expect(SimulatorContainer.containerArguments(
        bundleIdentifier: "dev.example.App", deviceIdentifier: "SIMULATOR-ID") == [
            "simctl", "get_app_container", "SIMULATOR-ID", "dev.example.App", "data",
        ])
    #expect(SimulatorContainer.containerArguments(
        bundleIdentifier: "dev.example.App", deviceIdentifier: nil) == [
            "simctl", "get_app_container", "booted", "dev.example.App", "data",
        ])
}

@Test func xcrunWarningsDoNotBecomePartOfTheToolPath() throws {
    let result = Subprocess.SeparatedResult(
        exitCode: 0,
        standardOutput: "/bin/sh\n",
        standardError: "Warning: unknown environment variable SWIFT_DEBUG_INFORMATION_FORMAT\n")

    #expect(try XcodeProject.toolPath("swiftc", from: result) == "/bin/sh")
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
    #expect(context.excludedSourcePaths.isEmpty)
    #expect(context.simulatorIdentifier == nil)
}

@Test func aBuildContextRoundTrips() throws {
    let original = BuildContext(
        moduleName: "A", swiftCompilerPath: "/x", swiftCompilerVersion: "v",
        targetTriple: "t", sdkPath: "/s", sdkName: "n", appBinaryPath: "/b",
        moduleSearchPaths: ["/m"], extraCompilerFlags: ["-D", "X"],
        sourceRoots: ["/r"], bundleIdentifier: "id",
        debugDylibPath: "/b.debug.dylib", frameworkSearchPaths: ["/f"],
        deviceIdentifier: "DEVICE-ID", codeSigningIdentity: "SIGNING-SHA",
        excludedSourcePaths: ["/r/Generated", "/r/Fixture.swift"])
    let decoded = try JSONDecoder().decode(
        BuildContext.self, from: try JSONEncoder().encode(original))
    #expect(decoded.identity == original.identity)
    #expect(decoded.debugDylibPath == original.debugDylibPath)
    #expect(decoded.frameworkSearchPaths == original.frameworkSearchPaths)
    #expect(decoded.linkTarget == original.linkTarget)
    #expect(decoded.deviceIdentifier == original.deviceIdentifier)
    #expect(decoded.simulatorIdentifier == original.simulatorIdentifier)
    #expect(decoded.codeSigningIdentity == original.codeSigningIdentity)
    #expect(decoded.excludedSourcePaths == original.excludedSourcePaths)

    var simulator = original
    simulator.deviceIdentifier = nil
    simulator.simulatorIdentifier = "SIMULATOR-ID"
    let decodedSimulator = try JSONDecoder().decode(
        BuildContext.self, from: try JSONEncoder().encode(simulator))
    #expect(decodedSimulator.deviceIdentifier == nil)
    #expect(decodedSimulator.simulatorIdentifier == "SIMULATOR-ID")
}

@Test func signingIdentityPrefersTheExpandedIdentityAndRejectsPlaceholders() {
    #expect(XcodeProject.signingIdentity(from: [
        "EXPANDED_CODE_SIGN_IDENTITY": "expanded",
        "CODE_SIGN_IDENTITY": "Apple Development",
    ]) == "expanded")
    #expect(XcodeProject.signingIdentity(from: ["CODE_SIGN_IDENTITY": "-"]) == nil)
}

@Test func physicalDeviceWatchRejectsASimulatorContextAndMissingSigning() {
    var context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/swiftc", swiftCompilerVersion: "6",
        targetTriple: "arm64-apple-ios16.0-simulator", sdkPath: "/sdk",
        sdkName: "iphonesimulator", appBinaryPath: "/App", moduleSearchPaths: [],
        extraCompilerFlags: [], sourceRoots: [], bundleIdentifier: "id",
        deviceIdentifier: "DEVICE-ID", codeSigningIdentity: "SIGNING")
    #expect(throws: EmberError.self) { try Watch.validatePhysicalDevice(context) }

    context.targetTriple = "arm64-apple-ios16.0"
    context.sdkName = "iphoneos"
    context.codeSigningIdentity = nil
    #expect(throws: EmberError.self) { try Watch.validatePhysicalDevice(context) }

    context.codeSigningIdentity = "SIGNING"
    #expect(throws: Never.self) { try Watch.validatePhysicalDevice(context) }
}

@Test func doctorChecksOnlyModulesReachableFromWatchedSources() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-doctor-modules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let package = root.appendingPathComponent("FeaturePackage")
    let feature = package.appendingPathComponent("Sources/Feature")
    let helper = package.appendingPathComponent("Sources/Helper")
    try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
    try "// package\n".write(to: package.appendingPathComponent("Package.swift"),
                              atomically: true, encoding: .utf8)
    try "struct Screen {}\n".write(to: feature.appendingPathComponent("Screen.swift"),
                                    atomically: true, encoding: .utf8)
    try "struct HiddenHelper {}\n".write(to: helper.appendingPathComponent("Helper.swift"),
                                          atomically: true, encoding: .utf8)

    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/swiftc", swiftCompilerVersion: "6",
        targetTriple: "arm64-apple-ios16.0-simulator", sdkPath: "/sdk",
        sdkName: "iphonesimulator", appBinaryPath: "/App", moduleSearchPaths: [],
        extraCompilerFlags: [], sourceRoots: [package.appendingPathComponent("Sources").path],
        bundleIdentifier: "id",
        excludedSourcePaths: [helper.path])

    #expect(Doctor.watchedModules(context: context) == ["Feature"])
}

@Test func physicalLoadFailuresKeepTheirStructuredRecovery() {
    let original = EmberError(stage: .transfer, subject: "Patch.dylib",
                               reason: "the signing team does not match",
                               recovery: .configure)
    let failure = PatchCoordinator.loadFailure(from: original, subject: "Screen.swift")

    #expect(failure.stage == .transfer)
    #expect(failure.subject == "Patch.dylib")
    #expect(failure.reason == original.reason)
    #expect(failure.recovery == .configure)
    #expect(!PatchCoordinator.cannotDescribeProcess(after: original))

    let unknownOutcome = EmberError(stage: .load, subject: "Patch.dylib",
                                     reason: "the device did not answer",
                                     recovery: .restart)
    #expect(PatchCoordinator.cannotDescribeProcess(after: unknownOutcome))
}

// MARK: - Diagnostics that are really build settings

/// The compiler says "module was not compiled for private import" and stops.
/// Left alone, a project missing the setting is shown that against generated
/// source it never wrote, at a line it cannot open.
@Test func aMissingPrivateImportIsExplainedAsASetting() {
    let output = """
    /tmp/.ember/Patch_001.swift:3:54: error: module 'App' was not compiled for private import
    """
    let explanation = PatchCompiler.explain(output)
    #expect(explanation?.contains("-enable-private-imports") == true)
    #expect(explanation?.contains("unsafeFlags") == true)
    #expect(explanation?.contains("rebuild") == true)
}

@Test func anOrdinaryCompileErrorIsLeftAlone() {
    #expect(PatchCompiler.explain("error: cannot find 'x' in scope") == nil)
}

@Test func aMissingClangModuleCanBeRecoveredPrecisely() {
    let output = "<unknown>:0: error: missing required module 'GRDBSQLite'"
    #expect(PatchCompiler.missingRequiredModule(in: output) == "GRDBSQLite")
    #expect(PatchCompiler.missingRequiredModule(in: "no such module 'GRDBSQLite'") == nil)

    #expect(PatchCompiler.moduleMap("module GRDBSQLite [system] {\n}",
                                   declares: "GRDBSQLite"))
    #expect(PatchCompiler.moduleMap("framework module GRDB {\n}", declares: "GRDB"))
    #expect(!PatchCompiler.moduleMap("module GRDB {\n}", declares: "GRDBSQLite"))
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
