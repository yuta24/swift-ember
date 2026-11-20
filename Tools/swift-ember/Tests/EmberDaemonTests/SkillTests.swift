import Foundation
import Testing
@testable import EmberCLI

private struct SkillFixture {
    let root: URL
    let checkout: URL
    let source: URL
    let app: URL
    let home: URL

    init(root: URL) throws {
        self.root = root
        checkout = root.appendingPathComponent("checkout", isDirectory: true)
        source = checkout.appendingPathComponent("skills/swift-ember", isDirectory: true)
        app = root.appendingPathComponent("app", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try write("Skill", to: source.appendingPathComponent("SKILL.md"))
        try write("Reference", to: source.appendingPathComponent("references/logs.md"))
        try write("Package", to: checkout.appendingPathComponent("Tools/swift-ember/Package.swift"))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    func write(_ value: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    func run(
        _ arguments: String...,
        cwd: URL? = nil,
        version: String = "1.0.0",
        withSource: Bool = true
    ) throws -> String {
        var lines: [String] = []
        try SkillCommand.parse(arguments).run(
            currentDirectory: cwd ?? app, home: home, executable: nil,
            environment: ["SWIFT_EMBER_HOME": withSource ? checkout.path : root.appendingPathComponent("missing").path],
            version: version,
            output: { lines.append($0) })
        return lines.joined(separator: "\n")
    }
}

private func withSkillFixture(_ operation: (SkillFixture) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-skill-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(SkillFixture(root: directory))
}

@Test func skillCommandValidatesScopeAndForce() throws {
    #expect(try SkillCommand.parse(["install", "--global"]).scope == .global)
    #expect(try SkillCommand.parse(["uninstall", "--dir", "some skills"]).scope == .directory("some skills"))
    #expect(try SkillCommand.parse(["uninstall", "--force"]).force)
    #expect(try SkillCommand.parse(["install", "--help"]).action == .help)
    for arguments in [
        ["install", "--global", "--dir", "skills"],
        ["install", "--global", "--global"],
        ["install", "--dir", "--force"],
        ["status", "--force"],
        ["unknown"],
    ] {
        #expect(throws: (any Error).self) { try SkillCommand.parse(arguments) }
    }
}

@Test func skillDefaultsToGitRootAndStatusShowsBothScopes() throws {
    try withSkillFixture { fixture in
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", fixture.app.path, "init", "-q", "--template="]
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let nested = fixture.app.appendingPathComponent("Sources/Features", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try fixture.run("install", cwd: nested)
        _ = try fixture.run("install", "--global", cwd: nested)
        let status = try fixture.run("status", cwd: nested)
        #expect(status.contains("/app/.claude/skills/swift-ember (installed by swift-ember 1.0.0"))
        #expect(status.contains("/home/.claude/skills/swift-ember (installed by swift-ember 1.0.0"))
        #expect(!status.contains("Sources/Features/.claude"))
        #expect(FileManager.default.fileExists(atPath: fixture.app.appendingPathComponent(
            ".claude/skills/swift-ember/references/logs.md").path))
    }
}

@Test func skillCopiesUpdatesAndUninstallsWithoutAnAvailableSource() throws {
    try withSkillFixture { fixture in
        let target = fixture.app.appendingPathComponent("custom skills/swift-ember", isDirectory: true)
        let destination = target.appendingPathComponent("SKILL.md")
        _ = try fixture.run("install", "--dir", "custom skills")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Skill")
        try fixture.write("Updated", to: fixture.source.appendingPathComponent("SKILL.md"))
        let stale = try fixture.run("status", "--dir", "custom skills", version: "2.0.0")
        #expect(stale.contains("version mismatch: this is swift-ember 2.0.0"))
        #expect(stale.contains("the available source differs"))
        _ = try fixture.run("install", "--dir", "custom skills", version: "2.0.0")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Updated")
        let status = try fixture.run("status", "--dir", "custom skills", version: "2.0.0", withSource: false)
        #expect(status.contains("! source"))
        #expect(!status.contains("version mismatch"))
        #expect(try fixture.run("uninstall", "--dir", "custom skills", withSource: false).hasPrefix("removed "))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try fixture.run("uninstall", "--dir", "custom skills", withSource: false).contains("not installed"))
    }
}

@Test func locallyChangedSkillListsChangesAndCanBeForced() throws {
    try withSkillFixture { fixture in
        let target = fixture.app.appendingPathComponent(".claude/skills/swift-ember")
        _ = try fixture.run("install")
        let main = target.appendingPathComponent("SKILL.md")
        let notes = target.appendingPathComponent("notes.md")
        try fixture.write("My custom skill", to: main)
        try fixture.write("My notes", to: notes)
        try FileManager.default.removeItem(at: target.appendingPathComponent("references/logs.md"))
        for action in ["install", "uninstall"] {
            do {
                _ = try fixture.run(action)
                Issue.record("Expected \(action) to reject the changed skill")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("changed: SKILL.md"))
                #expect(message.contains("added: notes.md"))
                #expect(message.contains("missing: references/logs.md"))
                #expect(message.contains("--force"))
            }
        }
        #expect(try String(contentsOf: main, encoding: .utf8) == "My custom skill")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "My notes")
        #expect(try fixture.run("status").contains("added: notes.md"))

        _ = try fixture.run("install", "--force")
        #expect(try String(contentsOf: main, encoding: .utf8) == "Skill")
        #expect(!FileManager.default.fileExists(atPath: notes.path))
        try fixture.write("My notes again", to: notes)
        _ = try fixture.run("uninstall", "--force")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Test func skillForceInstallReplacesForeignEntriesButUninstallPreservesThem() throws {
    try withSkillFixture { fixture in
        let target = fixture.app.appendingPathComponent("custom/swift-ember")
        let other = fixture.root.appendingPathComponent("other", isDirectory: true)
        let original = other.appendingPathComponent("notes.md")
        try fixture.write("Keep me", to: original)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        #expect(try fixture.run("status", "--dir", "custom").contains("was not installed"))
        #expect(throws: (any Error).self) { try fixture.run("install", "--dir", "custom") }
        #expect(throws: (any Error).self) { try fixture.run("uninstall", "--dir", "custom", "--force") }
        _ = try fixture.run("install", "--dir", "custom", "--force")
        #expect(try String(contentsOf: original, encoding: .utf8) == "Keep me")
        #expect(try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8) == "Skill")
    }
}

@Test func skillFindsCheckoutAndPackagedSources() throws {
    try withSkillFixture { fixture in
        let built = fixture.checkout.appendingPathComponent(".build/debug/swift-ember")
        let checkoutSource = try SkillCommand.findSource(fixture.app, executable: built, environment: [:])
        #expect(checkoutSource.path == fixture.source.resolvingSymlinksInPath().path)
        let checkoutFromCWD = try SkillCommand.findSource(fixture.source, executable: nil, environment: [:])
        #expect(checkoutFromCWD.path == checkoutSource.path)

        let release = fixture.root.appendingPathComponent("release")
        let binary = release.appendingPathComponent("bin/swift-ember")
        let bundled = release.appendingPathComponent("skills/swift-ember")
        let prefixSource = release.appendingPathComponent("share/swift-ember/skills/swift-ember")
        try fixture.write("Release", to: bundled.appendingPathComponent("SKILL.md"))
        try fixture.write("Installed", to: prefixSource.appendingPathComponent("SKILL.md"))
        let source = try SkillCommand.findSource(fixture.app, executable: binary, environment: [:])
        #expect(source.path == bundled.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: bundled)
        let installed = try SkillCommand.findSource(fixture.app, executable: binary, environment: [:])
        #expect(installed.path == prefixSource.resolvingSymlinksInPath().path)
        #expect(throws: (any Error).self) {
            try SkillCommand.findSource(fixture.app, executable: binary, environment: ["SWIFT_EMBER_HOME": "nonexistent"])
        }
    }
}

@Test func skillRefusesInstallingIntoItsSourceEvenWithForce() throws {
    try withSkillFixture { fixture in
        let sourceParent = fixture.source.deletingLastPathComponent()
        #expect(throws: (any Error).self) { try fixture.run("install", "--dir", sourceParent.path, "--force") }
        let alias = fixture.app.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        #expect(throws: (any Error).self) {
            try fixture.run("install", "--dir", "alias/missing", "--force")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("missing").path))
        let contents = try String(contentsOf: fixture.source.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(contents == "Skill")
    }
}
