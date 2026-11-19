import Foundation
import Testing
@testable import EmberCLI

@Test func releaseDoctorDefaultsToReleaseEvenWithDebugProjectDefaults() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent(".swift-ember.json")
    try Data(#"{"project":"App.xcodeproj","scheme":"App","configuration":"Debug"}"#.utf8).write(to: config)

    let options = try Options.parse(["doctor", "--release"], environment: [:], currentDirectory: directory)
    #expect(options.configuration == "Release")
    #expect(options.scheme == "App")
    let custom = try Options.parse(["doctor", "--release", "--configuration", "Shipping"],
                                   environment: [:], currentDirectory: directory)
    #expect(custom.configuration == "Shipping")
    #expect(throws: Options.ParseError.self) {
        _ = try Options.parse(["doctor", "--release", "--context", "context.json"],
                              environment: [:], currentDirectory: directory)
    }
}

@Test func releaseDoctorChecksDirectAndForwardedFlags() {
    let findings = ReleaseDoctor.settingChecks([
        "OTHER_SWIFT_FLAGS": #"-Xfrontend "-enable-implicit-dynamic" -Xfrontend=-enable-private-imports -enable-testing -D "EMBER_ENABLED""#,
        "ENABLE_TESTABILITY": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "EMBER_ENABLED COMPATIBILITY",
    ]).map(\.1)
    #expect(findings[0] == ["-enable-implicit-dynamic", "-enable-private-imports"])
    #expect(findings[1] == ["ENABLE_TESTABILITY=YES", "-enable-testing"])
    #expect(findings[2].count == 2)

    let clean = ReleaseDoctor.settingChecks([
        "OTHER_SWIFT_FLAGS": #"-DEMBER_ENABLED_FOR_SOMETHING_ELSE -I "Some path -enable-private-imports or another""#,
        "SWIFT_ENABLE_TESTABILITY": "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MY_EMBER_ENABLED",
    ]).map(\.1)
    #expect(clean == [[], [], []])
}

@Test func releaseDoctorDetectsSingleQuotedCompilerFlags() {
    let findings = ReleaseDoctor.settingChecks([
        "OTHER_SWIFT_FLAGS": "'-DEMBER_ENABLED'\t-Xfrontend '-enable-private-imports'",
    ]).map(\.1)
    #expect(findings == [["-enable-private-imports"], [], ["OTHER_SWIFT_FLAGS defines EMBER_ENABLED"]])
}

@Test func initWrapsAnExistingBaseAndPreservesTheSharedScheme() throws {
    let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { directory, _ in
        directory.deletingLastPathComponent()
    }
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.copyItem(at: repository.appendingPathComponent("examples/XcodeApp"), to: root)
    defer { try? manager.removeItem(at: root) }
    let project = root.appendingPathComponent("XcodeApp.xcodeproj", isDirectory: true)
    let pbxproj = project.appendingPathComponent("project.pbxproj")
    let scheme = project.appendingPathComponent("xcshareddata/xcschemes/XcodeApp.xcscheme")
    let podsRelativePath = "Pods/Target Support Files/Pods-XcodeApp/Pods-XcodeApp.debug.xcconfig"
    let pods = root.appendingPathComponent(podsRelativePath)
    try manager.createDirectory(at: pods.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existingBase = Data("OTHER_SWIFT_FLAGS = $(inherited) -D EXISTING_FLAG\n".utf8)
    try existingBase.write(to: pods)

    let before = try String(contentsOf: pbxproj, encoding: .utf8)
        .replacingOccurrences(of: "../../integrations/xcode/Ember.xcconfig", with: "\"\(podsRelativePath)\"")
    try Data(before.utf8).write(to: pbxproj)
    let customScript = "echo first\necho second"
    let originalScheme = Data(try String(contentsOf: scheme, encoding: .utf8).replacingOccurrences(
        of: "<BuildActionEntries>",
        with: """
        <PreActions>
                 <ExecutionAction><ActionContent title="Custom pre" scriptText="echo first&#10;echo second"/></ExecutionAction>
              </PreActions>
              <PostActions>
                 <ExecutionAction><ActionContent title='Custom post' scriptText='echo &quot;finished &gt; started&quot;'/></ExecutionAction>
              </PostActions>
              <BuildActionEntries>
        """
    ).utf8)
    try originalScheme.write(to: scheme)

    let template = repository.appendingPathComponent("integrations/xcode/Ember.xcconfig")
    let arguments = ["init", "--project", project.path, "--scheme", "XcodeApp",
                     "--ember-xcconfig", template.path, "--post-action", "start"]
    let config = root.appendingPathComponent(".swift-ember.json")
    let wrapper = root.appendingPathComponent("Ember.XcodeApp.Debug.xcconfig")
    try XcodeInit.run(options: Options.parse(arguments, environment: [:], currentDirectory: root))
    #expect(try Data(contentsOf: pbxproj) == Data(before.utf8))
    #expect(try Data(contentsOf: scheme) == originalScheme)
    #expect(!manager.fileExists(atPath: config.path))
    #expect(!manager.fileExists(atPath: wrapper.path))

    let apply = try Options.parse(arguments + ["--write"], environment: [:], currentDirectory: root)
    try XcodeInit.run(options: apply)
    #expect(try Data(contentsOf: pods) == existingBase)
    let includes = try String(contentsOf: wrapper, encoding: .utf8)
        .split(separator: "\n").filter { $0.hasPrefix("#include") }
    #expect(includes.count == 2)
    #expect(includes.first == "#include \"\(podsRelativePath)\"")
    #expect(includes.last?.hasSuffix("integrations/xcode/Ember.xcconfig\"") == true)

    let updatedProject = try Data(contentsOf: pbxproj)
    let updatedScheme = try Data(contentsOf: scheme)
    expectOnlyAddedLines(from: originalScheme, to: updatedScheme)
    let document = try XMLDocument(data: updatedScheme)
    let actions = try document.nodes(forXPath: "/Scheme/BuildAction/*/ExecutionAction/ActionContent")
        .compactMap { $0 as? XMLElement }
    try #require(actions.map { $0.attribute(forName: "title")?.stringValue }
            == ["Custom pre", "swift-ember prepare", "Custom post", "swift-ember start"])
    #expect(actions.first?.attribute(forName: "scriptText")?.stringValue == customScript)
    for action in [actions[1], actions[3]] {
        let script = action.attribute(forName: "scriptText")?.stringValue
        #expect(script?.split(separator: "\n").count == 3)
        let app = try action.nodes(forXPath: "EnvironmentBuildable/BuildableReference/@BlueprintIdentifier")
        #expect(app.first?.stringValue == "A1000006")
    }
    try XcodeInit.run(options: apply)
    #expect(try Data(contentsOf: pbxproj) == updatedProject)
    #expect(try Data(contentsOf: scheme) == updatedScheme)
}

@Test(arguments: [false, true])
func initSchemeKeepsEveryOriginalLine(useCRLF: Bool) throws {
    try withSampleScheme { scheme, arguments in
        if useCRLF {
            var original = try String(contentsOf: scheme, encoding: .utf8)
            original = original.replacingOccurrences(of: "      <BuildActionEntries>", with: """
                  <!-- 既存のコメント <PreActions></PreActions> -->
                  <BuildActionEntries>
            """)
            try #require(original.last == "\n")
            original.removeLast()
            try Data(original.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: scheme)
        }
        let before = try Data(contentsOf: scheme)
        try XcodeInit.run(options: Options.parse(arguments, environment: [:]))
        let after = try Data(contentsOf: scheme)
        expectOnlyAddedLines(from: before, to: after)
        #expect(after.last == before.last)
        let lines = after.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        #expect(lines.allSatisfy { ($0.last == 0x0D) == useCRLF })
        let xml = String(decoding: after, as: UTF8.self)
        #expect(xml.contains("      <PreActions>"))
        #expect(xml.contains("      <PostActions>"))
        #expect(xml.contains("               title = \"swift-ember record\""))
    }
}

@Test func initReplacesOnlyTheGeneratedPostActionAttributeValues() throws {
    try withSampleScheme { scheme, arguments in
        try XcodeInit.run(options: Options.parse(arguments, environment: [:]))
        let original = try String(contentsOf: scheme, encoding: .utf8)
        // Use the alternate valid attribute delimiter and retain custom
        // spacing to verify the source edit targets only the value.
        let edited = original.replacingOccurrences(of: "title = \"swift-ember record\"",
                                                    with: "title  =   'swift-ember record'")
        try Data(edited.utf8).write(to: scheme)

        let start = try Options.parse(arguments + ["--post-action", "start"], environment: [:])
        try XcodeInit.run(options: start)
        let expected = edited.replacingOccurrences(of: "'swift-ember record'", with: "'swift-ember start'")
            .replacingOccurrences(of: " xcode record --config ", with: " xcode start --config ")
        #expect(try Data(contentsOf: scheme) == Data(expected.utf8))
        try XcodeInit.run(options: start)
        #expect(try Data(contentsOf: scheme) == Data(expected.utf8))
    }
}

@Test func initLeavesCompactActionBlocksUntouchedAndExplainsManualSetup() throws {
    try withSampleScheme { scheme, arguments in
        let original = try String(contentsOf: scheme, encoding: .utf8)
        let before = Data(original.replacingOccurrences(of: "<BuildActionEntries>",
                                                        with: "<PreActions/><BuildActionEntries>").utf8)
        try before.write(to: scheme)
        let options = try Options.parse(arguments, environment: [:])
        #expect(throws: InitError.self) { try XcodeInit.run(options: options) }
        #expect(try Data(contentsOf: scheme) == before)
        let directory = scheme.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".swift-ember.json").path))
    }
}

@Test func initRejectsAnOutOfRootManifestBeforeReadingIt() throws {
    try withInitPathFixture { root, outside, _, arguments in
        let config = "../\(outside.lastPathComponent)/config.json"
        try Data("invalid JSON".utf8).write(to: outside.appendingPathComponent("config.json"))
        let error = #expect(throws: Options.ParseError.self) {
            try Options.parse(arguments + ["--config", config], environment: [:], currentDirectory: root)
        }
        #expect(error?.description.contains(" is outside ") == true)
    }
}

@Test(arguments: [
    ".swift-ember.json",
    "Ember.XcodeApp.Debug.xcconfig",
    "XcodeApp.xcodeproj/project.pbxproj",
    "XcodeApp.xcodeproj/xcshareddata/xcschemes/XcodeApp.xcscheme",
])
func initRejectsSymlinksFromManagedFilesToOutsideTheRoot(path: String) throws {
    try withInitPathFixture { root, outside, _, arguments in
        let manager = FileManager.default
        let file = root.appendingPathComponent(path)
        let external = outside.appendingPathComponent(file.lastPathComponent)
        if path == ".swift-ember.json" {
            try Data(#"{"project":"XcodeApp.xcodeproj","scheme":"XcodeApp"}"#.utf8).write(to: external)
        } else if path.hasSuffix(".xcconfig") {
            _ = try useLocalBaseConfiguration(in: root)
            try Data("SWIFT_VERSION = 5.0\n".utf8).write(to: external)
        } else {
            try manager.moveItem(at: file, to: external)
        }
        try manager.createSymbolicLink(at: file, withDestinationURL: external)
        let before = try Data(contentsOf: external)
        let options = try Options.parse(arguments, environment: [:])
        let error = #expect(throws: InitError.self) { try XcodeInit.run(options: options) }
        #expect(error?.description.contains(" is outside ") == true)
        #expect(try Data(contentsOf: external) == before)
    }
}

@Test(arguments: [false, true])
func initRejectsSymlinksInPathsToUncreatedFiles(danglingLeaf: Bool) throws {
    try withInitPathFixture { root, outside, scheme, arguments in
        let manager = FileManager.default
        let link = root.appendingPathComponent("redirect")
        let external = outside.appendingPathComponent("new.json")
        try manager.createSymbolicLink(at: link, withDestinationURL: danglingLeaf ? external : outside)
        var options = try Options.parse(arguments, environment: [:])
        options.configPath = (danglingLeaf ? link : link.appendingPathComponent("new.json")).path
        let before = try Data(contentsOf: scheme)
        let error = #expect(throws: InitError.self) { try XcodeInit.run(options: options) }
        #expect(error?.description.contains(danglingLeaf ? "cannot resolve symbolic link" : " is outside ") == true)
        #expect(!manager.fileExists(atPath: external.path))
        #expect(try Data(contentsOf: scheme) == before)
    }
}

@Test func initRejectsAnUnapprovedExternalXCConfigInclude() throws {
    try withInitPathFixture { root, outside, _, arguments in
        let config = root.appendingPathComponent("Ember.xcconfig")
        try FileManager.default.copyItem(at: config, to: outside.appendingPathComponent("Ember.xcconfig"))
        try Data("#include \"../\(outside.lastPathComponent)/Ember.xcconfig\"\n".utf8).write(to: config)
        let options = try Options.parse(arguments, environment: [:])
        let error = #expect(throws: InitError.self) { try XcodeInit.run(options: options) }
        #expect(error?.description.contains(" is outside ") == true)
    }
}

@Test(arguments: [false, true])
func initAllowsAListedExternalWorkspaceProject(workspaceOwnsScheme: Bool) throws {
    try withInitPathFixture { root, outside, projectScheme, _ in
        let manager = FileManager.default
        let workspace = outside.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let reference = "../\(root.lastPathComponent)/XcodeApp.xcodeproj"
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        try Data("<Workspace><FileRef location=\"group:\(reference)\"/></Workspace>".utf8).write(to: contents)

        let originalScheme = try String(contentsOf: projectScheme, encoding: .utf8)
        let scheme: URL
        if workspaceOwnsScheme {
            scheme = workspace.appendingPathComponent("xcshareddata/xcschemes/XcodeApp.xcscheme")
            try manager.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(originalScheme.replacingOccurrences(
                of: "container:XcodeApp.xcodeproj", with: "container:\(reference)"
            ).utf8).write(to: scheme)
        } else {
            scheme = projectScheme
        }
        let projectFile = try useLocalBaseConfiguration(in: root)
        let options = try Options.parse(["init", "--workspace", workspace.path, "--scheme", "XcodeApp", "--write"],
                                        environment: [:])
        try XcodeInit.run(options: options)
        let wrapperName = "Ember.XcodeApp.Debug.xcconfig"
        let wrapper = try String(contentsOf: root.appendingPathComponent(wrapperName), encoding: .utf8)
        #expect(wrapper.contains("#include \"Local.xcconfig\""))
        #expect(try String(contentsOf: projectFile, encoding: .utf8).contains(wrapperName))
        let updatedScheme = try String(contentsOf: scheme, encoding: .utf8)
        #expect(updatedScheme.contains("swift-ember prepare"))
        #expect(updatedScheme.contains("../\(outside.lastPathComponent)/.swift-ember.json"))
        #expect(manager.fileExists(atPath: outside.appendingPathComponent(".swift-ember.json").path))
        #expect(!manager.fileExists(atPath: outside.appendingPathComponent(wrapperName).path))
        #expect(!manager.fileExists(atPath: root.appendingPathComponent(".swift-ember.json").path))
        if workspaceOwnsScheme {
            #expect(try String(contentsOf: projectScheme, encoding: .utf8) == originalScheme)
        }
        try XcodeInit.run(options: options)

        if workspaceOwnsScheme {
            try Data("<Workspace/>".utf8).write(to: contents)
            let error = #expect(throws: InitError.self) { try XcodeInit.run(options: options) }
            #expect(error?.description.contains(" is outside ") == true)
        }
    }
}

private func useLocalBaseConfiguration(in root: URL) throws -> URL {
    let projectFile = root.appendingPathComponent("XcodeApp.xcodeproj/project.pbxproj")
    let project = try String(contentsOf: projectFile, encoding: .utf8)
        .replacingOccurrences(of: "path = Ember.xcconfig", with: "path = Local.xcconfig")
    try Data(project.utf8).write(to: projectFile)
    try Data("SWIFT_VERSION = 6.0\n".utf8).write(to: root.appendingPathComponent("Local.xcconfig"))
    return projectFile
}

private func withInitPathFixture(_ body: (URL, URL, URL, [String]) throws -> Void) throws {
    try withSampleScheme { scheme, arguments in
        let root = (0..<4).reduce(scheme) { directory, _ in directory.deletingLastPathComponent() }
        // A sibling whose path shares the entire root prefix still lies outside.
        let outside = URL(fileURLWithPath: root.path + "-outside", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: outside) }
        try body(root, outside, scheme, arguments)
    }
}

private func expectOnlyAddedLines(from original: Data, to edited: Data) {
    var remaining = original.split(separator: 0x0A, omittingEmptySubsequences: false)[...]
    for line in edited.split(separator: 0x0A, omittingEmptySubsequences: false) where line == remaining.first {
        remaining = remaining.dropFirst()
    }
    #expect(remaining.isEmpty)
}

private func withSampleScheme(_ body: (URL, [String]) throws -> Void) throws {
    let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { directory, _ in
        directory.deletingLastPathComponent()
    }
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.copyItem(at: repository.appendingPathComponent("examples/XcodeApp"), to: root)
    defer { try? manager.removeItem(at: root) }
    let project = root.appendingPathComponent("XcodeApp.xcodeproj", isDirectory: true)
    let pbxproj = project.appendingPathComponent("project.pbxproj")
    let scheme = project.appendingPathComponent("xcshareddata/xcschemes/XcodeApp.xcscheme")
    try manager.copyItem(at: repository.appendingPathComponent("integrations/xcode/Ember.xcconfig"),
                         to: root.appendingPathComponent("Ember.xcconfig"))
    let text = try String(contentsOf: pbxproj, encoding: .utf8)
        .replacingOccurrences(of: "../../integrations/xcode/Ember.xcconfig", with: "Ember.xcconfig")
    try Data(text.utf8).write(to: pbxproj)
    try body(scheme, ["init", "--project", project.path, "--scheme", "XcodeApp", "--write"])
}
