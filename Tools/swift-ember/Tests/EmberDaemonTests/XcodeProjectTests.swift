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
