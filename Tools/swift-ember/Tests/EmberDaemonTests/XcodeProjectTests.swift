import Foundation
import Testing
import EmberCore
@testable import EmberDaemon

private let products = "/Build Output/Build/Products/Debug-iphonesimulator"
private let appSettings = [
    "WRAPPER_EXTENSION": "app",
    "PLATFORM_NAME": "iphonesimulator",
    "BUILT_PRODUCTS_DIR": products,
    "TARGET_BUILD_DIR": products,
    "EXECUTABLE_PATH": "App.app/App",
    "ENABLE_DEBUG_DYLIB": "YES",
    "FRAMEWORK_SEARCH_PATHS": "\"\(products)/PackageFrameworks\"",
]

@Test func schemeBuildUsesItsOwnSettingsWithoutQueryingXcodebuild() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    let settings = try project.buildSettings(schemeEnvironment: appSettings) {
        Issue.record("A Scheme action should not query xcodebuild for the default output")
        return [:]
    }
    let output = try project.buildProducts(from: settings, schemeAction: true)
    #expect(settings == appSettings)
    #expect(output.directory == products)
    #expect(output.executable == "\(products)/App.app/App")
    #expect(output.linkTarget == "\(products)/App.app/App.debug.dylib")
}

@Test func schemeBuildResolvesTheSDKDirectoryWhenSDKROOTIsAName() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    let sdk = "/Xcode SDKs/iPhoneSimulator27.2.sdk"
    var settings = appSettings
    settings["PRODUCT_MODULE_NAME"] = "App"
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.example.App"
    settings["SDKROOT"] = "iphonesimulator27.2"
    settings["SDK_DIR"] = sdk
    let action = try project.resolve(sourceRoots: ["/Sources"], schemeBuildSettings: settings,
                                     allowsMissingSchemeBinary: true)
    #expect(action.context.sdkPath == sdk)

    settings["SDKROOT"] = sdk
    settings["SDK_DIR"] = nil
    let absolute = try project.resolve(sourceRoots: ["/Sources"], schemeBuildSettings: settings,
                                       allowsMissingSchemeBinary: true)
    #expect(absolute.context.sdkPath == sdk)
}

@Test func xcodeUsesTargetBuildDirectoryForAnAppOutsideBuiltProducts() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    var settings = appSettings
    settings["TARGET_BUILD_DIR"] = "/Installed Apps"
    settings["ENABLE_DEBUG_DYLIB"] = "NO"
    let installed = try project.buildProducts(from: settings, schemeAction: true)
    #expect(installed.directory == products)
    #expect(installed.linkTarget == "/Installed Apps/App.app/App")

    settings["TARGET_BUILD_DIR"] = nil
    let regular = try project.buildProducts(from: settings, schemeAction: true)
    #expect(regular.linkTarget == "\(products)/App.app/App")
}

@Test func schemeBuildPreservesQuotedAndEscapedCompilerArguments() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    var settings = appSettings
    settings["PRODUCT_NAME"] = "App"
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = "example.App"
    settings["SDKROOT"] = "/SDK"
    settings["SRCROOT"] = "/Source"
    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    settings["OTHER_SWIFT_FLAGS"] =
        #"-Xcc "-I/path with space" -D 'FLAG' -I /another\ path -F/quoted" suffix" -Xcc "-DNAME=\"some text\"""#
        + #" -Xcc "" -I '/日本語/Owner\'s\\Headers'"#
    settings["SWIFT_INCLUDE_PATHS"] = "'/Swift Modules'\t/More\\ Modules"
    settings["FRAMEWORK_SEARCH_PATHS"] = #""/Frameworks \"Debug\"" '/More Frameworks'"#

    let context = try project.resolve(sourceRoots: [], schemeBuildSettings: settings,
                                      allowsMissingSchemeBinary: true).context
    #expect(context.extraCompilerFlags == [
        "-D", "DEBUG", "-Xcc", "-I/path with space", "-D", "FLAG",
        "-I", "/another path", "-F/quoted suffix", "-Xcc", #"-DNAME="some text""#,
        "-Xcc", "", "-I", #"/日本語/Owner's\Headers"#,
    ])
    #expect(context.moduleSearchPaths == [
        products, "\(products)/App.swiftmodule", "/Swift Modules", "/More Modules",
    ])
    #expect(context.frameworkSearchPaths == [products, #"/Frameworks "Debug""#, "/More Frameworks"])
}

@Test func incompleteSchemeBuildSettingsDiagnoseTheMissingSetting() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    let targetError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: [:])
    }
    #expect(targetError.reason.contains("Provide build settings from"))

    var settings = appSettings
    settings["BUILT_PRODUCTS_DIR"] = nil
    let directoryError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: settings)
    }
    #expect(directoryError.reason.contains("BUILT_PRODUCTS_DIR"))
    #expect(directoryError.reason.contains("Scheme Build action"))
}

@Test func schemePreActionCanResolveBeforeTheLinkTargetExists() throws {
    let project = XcodeProject(container: .project("App.xcodeproj"), scheme: "App")
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var settings = appSettings
    settings["TARGET_BUILD_DIR"] = output.path
    let postActionError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: settings)
    }
    #expect(postActionError.reason.contains("binary is missing"))

    // The pre-action gets as far as resolving the remaining build settings.
    let preActionError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: settings,
                            allowsMissingSchemeBinary: true)
    }
    #expect(preActionError.reason.contains("did not provide PRODUCT_NAME"))
}

@Test func explicitDerivedDataIsPassedToXcodebuildAndCheckedAgainstSchemeOutput() throws {
    let project = XcodeProject(container: .workspace("App.xcworkspace"), scheme: "App",
                               simulatorIdentifier: "SIMULATOR-ID", derivedDataPath: "/Build Output")
    #expect(project.buildSettingsArguments == [
        "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "-configuration", "Debug",
        "-destination", "id=SIMULATOR-ID", "-showBuildSettings", "-json", "-derivedDataPath", "/Build Output",
    ])
    #expect(try project.buildSettings(schemeEnvironment: nil) { appSettings } == appSettings)
    #expect(try project.buildSettings(schemeEnvironment: appSettings) { appSettings } == appSettings)

    var queried = appSettings
    queried["TARGET_BUILD_DIR"] = "/Other Build"
    let error = try #require(throws: EmberError.self) {
        try project.buildSettings(schemeEnvironment: appSettings) { queried }
    }
    #expect(error.reason.contains("--derived-data-path"))
    #expect(error.reason.contains("\(products)/App.app/App.debug.dylib"))
    #expect(error.reason.contains("/Other Build/App.app/App.debug.dylib"))
}

@Test func schemeBuildRejectsADifferentProjectOrPlatform() throws {
    let project = XcodeProject(container: .project("/Source/App.xcodeproj"), scheme: "App",
                               simulatorIdentifier: "SIMULATOR-ID")
    var settings = appSettings
    settings["PROJECT_FILE_PATH"] = "/Source/Other.xcodeproj"
    let projectError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: settings)
    }
    #expect(projectError.reason.contains("PROJECT_FILE_PATH"))
    #expect(projectError.reason.contains("/Source/Other.xcodeproj"))

    settings["PROJECT_FILE_PATH"] = "/Source/App.xcodeproj"
    settings["PLATFORM_NAME"] = "iphoneos"
    let platformError = try #require(throws: EmberError.self) {
        try project.resolve(sourceRoots: [], schemeBuildSettings: settings)
    }
    #expect(platformError.reason.contains("PLATFORM_NAME"))
}

@Test func xcodeIgnoresInTreeOutputsUsingSchemeOrTerminalSettings() {
    let root = "/Projects/App"
    let derived = root + "/Local Build"
    let settings = [
        "SRCROOT": root,
        "BUILT_PRODUCTS_DIR": derived + "/Build/Products/Debug-iphonesimulator",
        "OBJROOT": derived + "/Build/Intermediates.noindex",
        "TARGET_BUILD_DIR": root + "/Installed Products",
        "DERIVED_FILE_DIR": root + "/Custom Generated",
        "TARGET_TEMP_DIR": root + "/Custom Generated/Temp",
        "SYMROOT": root,
    ]
    let scheme = XcodeProject(container: .project(root + "/App.xcodeproj"), scheme: "App")
    let terminal = XcodeProject(container: scheme.container, scheme: "App", derivedDataPath: derived)
    let expected = [root + "/Custom Generated", root + "/Installed Products", derived]
    #expect(scheme.buildOutputPaths(from: settings, sourceRoots: [root]) == expected)
    #expect(terminal.buildOutputPaths(from: settings, sourceRoots: [root]) == expected)
    #expect(scheme.buildOutputPaths(from: settings, sourceRoots: [root + "/Sources"]).isEmpty)

    let withProjectLocalIntermediates = [
        "SRCROOT": root,
        "BUILT_PRODUCTS_DIR": root + "/Products",
        "OBJROOT": root + "/Intermediates",
    ]
    #expect(scheme.buildOutputPaths(from: withProjectLocalIntermediates, sourceRoots: [root])
        == [root + "/Intermediates", root + "/Products"])
}

@Test func xcodeSourceMembershipFollowsLocalFrameworkDependencies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-xcode-modules-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("App.xcodeproj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
        {
          objects = {
            APP = { isa = PBXNativeTarget; name = App; dependencies = (DEPENDENCY); };
            DEPENDENCY = { isa = PBXTargetDependency; target = KIT; };
            KIT = { isa = PBXNativeTarget; name = FrameworkTarget; productType = "com.apple.product-type.framework"; };
            OTHER = { isa = PBXNativeTarget; name = Other; productType = "com.apple.product-type.framework"; };
          };
        }
        """.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

    let configuration = root.appendingPathComponent("Debug")
    let appDirectory = configuration.appendingPathComponent("App.build")
    let frameworkDirectory = configuration.appendingPathComponent("FrameworkTarget.build")
    let shared = root.appendingPathComponent("Shared Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let appSource = shared.appendingPathComponent("App.swift")
    let frameworkSource = shared.appendingPathComponent("Greeter.swift")
    let duplicate = shared.appendingPathComponent("Both.swift")
    let unscheduled = shared.appendingPathComponent("Unscheduled.swift")

    func writeBuildOutputs(_ directory: URL, product: String, module: String, sources: [URL]) throws {
        let objects = directory.appendingPathComponent("Objects-normal/arm64")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try Data().write(to: objects.appendingPathComponent("\(module).swiftmodule"))
        try sources.map(\.path).joined(separator: "\n")
            .write(to: objects.appendingPathComponent("\(product).SwiftFileList"), atomically: true, encoding: .utf8)
    }

    try writeBuildOutputs(appDirectory, product: "App", module: "App", sources: [appSource, duplicate])
    try writeBuildOutputs(frameworkDirectory, product: "FrameworkProduct", module: "FeatureKit",
                          sources: [frameworkSource, duplicate])
    try writeBuildOutputs(configuration.appendingPathComponent("Other.build"),
                          product: "Other", module: "Other", sources: [unscheduled])

    let app = [
        "TARGET_NAME": "App",
        "PRODUCT_NAME": "App",
        "PRODUCT_MODULE_NAME": "App",
        "TARGET_TEMP_DIR": appDirectory.path,
        "CONFIGURATION_TEMP_DIR": configuration.path,
        "PROJECT_FILE_PATH": project.path,
    ]
    var context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/swiftc", swiftCompilerVersion: "test",
        targetTriple: "arm64-apple-macosx14.0", sdkPath: "/", sdkName: "macosx",
        appBinaryPath: "/unused", moduleSearchPaths: [], extraCompilerFlags: [],
        sourceRoots: [shared.path], bundleIdentifier: "dev.ember.resolver-tests",
        xcodeSourceTargets: XcodeProject.sourceTargets(appSettings: app, queriedTargets: []))
    let cache = root.appendingPathComponent(".cache")
    var resolver = ModuleResolver(context: context, cacheDirectory: cache)
    #expect(try resolver.resolve(appSource).get().module == "App")
    #expect(try resolver.resolve(frameworkSource).get().module == "FeatureKit")
    let error = try #require(throws: ModuleResolver.Failure.self) { try resolver.resolve(duplicate).get() }
    #expect(error.description.contains("multiple targets compile this source (App, FeatureKit)"))
    #expect(throws: ModuleResolver.Failure.self) { try resolver.resolve(unscheduled).get() }

    let framework = [
        "WRAPPER_EXTENSION": "framework",
        "PRODUCT_NAME": "FrameworkProduct",
        "PRODUCT_MODULE_NAME": "FeatureKit",
        "TARGET_TEMP_DIR": frameworkDirectory.path,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FEATURE_DEBUG",
    ]
    context.xcodeSourceTargets = XcodeProject.sourceTargets(appSettings: app, queriedTargets: [framework])
    context.sourceModules = [shared.path: "FeatureKit", duplicate.path: "App"]
    resolver = ModuleResolver(context: context, cacheDirectory: cache)
    #expect(try resolver.resolve(unscheduled).get().module == "FeatureKit")
    #expect(try resolver.resolve(duplicate).get().module == "App")
    #expect(resolver.compilerFlags(for: "FeatureKit") == ["-D", "FEATURE_DEBUG"])
}

@Test func unbuiltXcodeTestTargetsAreRecognizedFromProjectMembership() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ember-xcode-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("App.xcodeproj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
        {
          rootObject = PROJECT;
          objects = {
            PROJECT = { isa = PBXProject; mainGroup = ROOT; };
            ROOT = { isa = PBXGroup; children = (UNITGROUP, UI, APPFILE); sourceTree = "<group>"; };
            UNITGROUP = { isa = PBXGroup; path = Custom; children = (UNITFILE); sourceTree = "<group>"; };
            UNITFILE = { isa = PBXFileReference; path = Unit.swift; sourceTree = "<group>"; };
            APPFILE = { isa = PBXFileReference; path = Shared.swift; sourceTree = SOURCE_ROOT; };
            UNITBUILD = { isa = PBXBuildFile; fileRef = UNITFILE; };
            SHAREDBUILD = { isa = PBXBuildFile; fileRef = APPFILE; };
            UNITPHASE = { isa = PBXSourcesBuildPhase; files = (UNITBUILD, SHAREDBUILD); };
            APPPHASE = { isa = PBXSourcesBuildPhase; files = (SHAREDBUILD); };
            UI = { isa = PBXFileSystemSynchronizedRootGroup; path = Automation; sourceTree = "<group>"; exceptions = (EXCEPT); };
            EXCEPT = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = UITEST; membershipExceptions = (Ignored.swift); };
            APP = { isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildPhases = (APPPHASE); };
            UNIT = { isa = PBXNativeTarget; productType = "com.apple.product-type.bundle.unit-test"; buildPhases = (UNITPHASE); };
            UITEST = { isa = PBXNativeTarget; productType = "com.apple.product-type.bundle.ui-testing"; fileSystemSynchronizedGroups = (UI); };
          };
        }
        """.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

    let membership = XcodeProject.projectSources(in: [["PROJECT_FILE_PATH": project.path]])
    var context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/usr/bin/swiftc", swiftCompilerVersion: "test",
        targetTriple: "arm64-apple-macosx14.0", sdkPath: "/", sdkName: "macosx",
        appBinaryPath: "/unused", moduleSearchPaths: [], extraCompilerFlags: [],
        sourceRoots: [root.path], bundleIdentifier: "dev.ember.resolver-tests", xcodeSourceTargets: [])
    context.xcodeTestSources = membership.test
    context.xcodeNonTestSources = membership.other
    let contextURL = root.appendingPathComponent("context.json")
    try context.write(to: contextURL)
    var resolver = ModuleResolver(
        context: try BuildContext.load(from: contextURL), cacheDirectory: root.appendingPathComponent(".cache"))
    let testMembership = [
        "Custom/Unit.swift", "Automation/Nested/Test.swift", "Shared.swift", "Automation/Ignored.swift",
    ].map { resolver.isTestSource(root.appendingPathComponent($0)) }
    #expect(testMembership == [true, true, false, false])
}
