import CryptoKit
import Darwin
import Foundation

public struct SkillCommand {
    enum Action: String { case install, status, uninstall, help }
    enum Scope: Equatable { case project, global, directory(String) }

    let action: Action
    var scope: Scope?
    var force = false

    public static let usage = """
    swift-ember skill install [--global | --dir <skills dir>] [--force]
    swift-ember skill status [--global | --dir <skills dir>]
    swift-ember skill uninstall [--global | --dir <skills dir>] [--force]

    Installs a copy in <git root>/.claude/skills/swift-ember (or the current
    directory's .claude/skills outside Git). --global uses ~/.claude/skills;
    --dir appends swift-ember to the specified skills directory. Without a
    scope, status shows both the project and global destinations.

    The source is bundled with the release or lives in a swift-ember checkout.
    Set SWIFT_EMBER_HOME to a checkout or extracted release root to select it
    explicitly. install --force replaces an existing entry. uninstall --force
    removes a modified copy with a valid swift-ember installation record.
    """

    public static func parse(_ arguments: [String]) throws -> Self {
        let helpFlags = ["help", "-h", "--help"]
        guard let first = arguments.first else { return Self(action: .help) }
        if helpFlags.contains(first) { return Self(action: .help) }
        guard let action = Action(rawValue: first) else {
            throw SkillError("skill takes install, status, or uninstall")
        }

        var options = Self(action: action)
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            switch flag {
            case "-h", "--help": return Self(action: .help)
            case "--force" where action != .status: options.force = true
            case "--global", "--dir":
                guard options.scope == nil else {
                    throw SkillError("choose one destination with --global or --dir")
                }
                if flag == "--global" {
                    options.scope = .global
                } else {
                    guard let path = rest.popFirst(), !path.isEmpty, !path.hasPrefix("-") else {
                        throw SkillError("--dir needs a skills directory")
                    }
                    options.scope = .directory(path)
                }
            default: throw SkillError("unknown skill option: \(flag)")
            }
        }
        return options
    }

    public func run(
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        executable: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        version: String = EmberVersion.current,
        output: (String) -> Void = { print($0) }
    ) throws {
        if action == .help { output(Self.usage); return }

        func destination(_ scope: Scope) -> URL {
            let skills: URL
            switch scope {
            case .project:
                skills = Self.projectRoot(currentDirectory).appendingPathComponent(".claude/skills", isDirectory: true)
            case .global:
                skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
            case .directory(let path):
                skills = Self.resolve(path, relativeTo: currentDirectory)
            }
            return Self.canonicalDirectory(skills).appendingPathComponent(SkillCopy.name, isDirectory: true)
        }

        switch action {
        case .install:
            let target = destination(scope ?? .project)
            let source = try Self.findSource(currentDirectory, executable: executable, environment: environment)
            try SkillCopy.install(from: source, to: target, version: version, force: force)
            output("installed the swift-ember skill in \(target.path) (swift-ember \(version), from \(source.path))")
        case .status:
            let source = Result {
                let url = try Self.findSource(currentDirectory, executable: executable, environment: environment)
                return (url, try SkillCopy.files(in: url))
            }
            let sourceFiles: [String: String]?
            switch source {
            case .success(let (url, files)):
                sourceFiles = files
                output("  ✓ source  \(url.path)")
            case .failure(let error):
                sourceFiles = nil
                output("  ! source  \(error)")
            }

            let scopes: [Scope] = scope.map { [$0] } ?? [.project, .global]
            for scope in scopes {
                let url = destination(scope)
                switch try SkillCopy.inspect(url) {
                case .absent:
                    output("  - \(url.path): not installed")
                case .foreign:
                    output("  ! \(url.path): was not installed by swift-ember")
                case .managed(let record, let changes):
                    let versionDiffers = record.version != version
                    let sourceDiffers = sourceFiles.map { $0 != record.files } ?? false
                    let mark = versionDiffers || sourceDiffers || !changes.isEmpty ? "!" : "✓"
                    output("  \(mark) \(url.path) (installed by swift-ember \(record.version) from \(record.source))")
                    if versionDiffers { output("    version mismatch: this is swift-ember \(version)") }
                    if sourceDiffers { output("    the available source differs from the installed snapshot") }
                    changes.forEach { output("    \($0)") }
                }
            }
        case .uninstall:
            let target = destination(scope ?? .project)
            let removed = try SkillCopy.uninstall(from: target, force: force)
            output(removed ? "removed \(target.path)" : "the swift-ember skill is not installed in \(target.path)")
        case .help: break
        }
    }

    private static func resolve(_ path: String, relativeTo directory: URL) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true, relativeTo: directory)
            .standardizedFileURL
    }

    // Foundation resolves symlinks in an existing path. Install destinations can
    // have missing directories below an existing symlink.
    private static func canonicalDirectory(_ url: URL) -> URL {
        var parent = url.standardizedFileURL
        var components: [String] = []
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            components.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        return components.reversed().reduce(parent.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    private static func projectRoot(_ directory: URL) -> URL {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory.path, "rev-parse", "--show-toplevel"]
        git.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        git.standardOutput = stdout
        do { try git.run() } catch { return directory }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard git.terminationStatus == 0, path.hasPrefix("/") else { return directory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func findSource(_ directory: URL, executable: URL?, environment: [String: String]) throws -> URL {
        func skill(in root: URL) -> URL {
            root.appendingPathComponent("skills/\(SkillCopy.name)", isDirectory: true).resolvingSymlinksInPath()
        }

        func containsSkill(_ source: URL) -> Bool {
            (try? SkillCopy.fileType(source.appendingPathComponent("SKILL.md"))) == .typeRegular
        }

        if let path = environment["SWIFT_EMBER_HOME"] {
            let source = skill(in: resolve(path, relativeTo: directory))
            guard containsSkill(source) else {
                throw SkillError("SWIFT_EMBER_HOME does not contain skills/swift-ember/SKILL.md: \(path)")
            }
            return source
        }

        let binaryDirectory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        if let prefix = binaryDirectory?.deletingLastPathComponent(), binaryDirectory?.lastPathComponent == "bin" {
            let bundled = skill(in: prefix)
            if containsSkill(bundled) { return bundled }
            let installed = skill(in: prefix.appendingPathComponent("share/swift-ember", isDirectory: true))
            if containsSkill(installed) { return installed }
        }

        for start in [binaryDirectory, directory].compactMap({ $0 }) {
            var root = start.standardizedFileURL
            while true {
                let source = skill(in: root)
                let manifest = root.appendingPathComponent("Tools/swift-ember/Package.swift")
                if containsSkill(source), (try? SkillCopy.fileType(manifest)) == .typeRegular { return source }
                guard root.path != "/" else { break }
                root.deleteLastPathComponent()
            }
        }

        throw SkillError("cannot find skills/swift-ember; use a complete release or set SWIFT_EMBER_HOME to a swift-ember checkout")
    }
}

private struct SkillError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum SkillCopy {
    static let name = "swift-ember"
    static let recordName = ".swift-ember-skill.json"

    struct Record: Codable {
        let skill: String
        let version: String
        let source: String
        let files: [String: String]
    }

    enum State {
        case absent
        case foreign
        case managed(Record, [String])
    }

    static func fileType(_ url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Relative paths and fingerprints protect local changes without storing a second copy of the skill.
    /// The root installation record is metadata and is excluded from the comparison.
    static func files(in directory: URL) throws -> [String: String] {
        let manager = FileManager.default
        var result: [String: String] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + item.lastPathComponent
                if path == recordName { continue }
                switch try fileType(item) {
                case .typeDirectory:
                    result[path] = "directory"
                    try visit(item, prefix: path + "/")
                case .typeRegular:
                    let digest = SHA256.hash(data: try Data(contentsOf: item))
                    result[path] = "sha256:" + Data(digest).base64EncodedString()
                case .typeSymbolicLink:
                    result[path] = "link:" + (try manager.destinationOfSymbolicLink(atPath: item.path))
                default:
                    result[path] = "other"
                }
            }
        }
        try visit(directory, prefix: "")
        return result
    }

    static func inspect(_ destination: URL) throws -> State {
        guard let type = try fileType(destination) else { return .absent }
        let marker = destination.appendingPathComponent(recordName)
        guard type == .typeDirectory, try fileType(marker) == .typeRegular,
              let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: marker)),
              record.skill == name, record.files["SKILL.md"] != nil else { return .foreign }

        let actual = try files(in: destination)
        let changes = Set(record.files.keys).union(actual.keys).sorted().compactMap { path -> String? in
            guard record.files[path] != actual[path] else { return nil }
            if record.files[path] == nil { return "added: \(path)" }
            if actual[path] == nil { return "missing: \(path)" }
            return "changed: \(path)"
        }
        return .managed(record, changes)
    }

    static func install(from source: URL, to destination: URL, version: String, force: Bool) throws {
        guard source.path != destination.path, !source.path.hasPrefix(destination.path + "/"),
              !destination.path.hasPrefix(source.path + "/") else {
            throw SkillError("cannot install the skill into its source tree: \(destination.path)")
        }

        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try withDirectoryLock(parent) {
            let state = try inspect(destination)
            switch state {
            case .foreign where !force:
                throw SkillError("\(destination.path) was not installed by swift-ember; pass --force to replace it")
            case .managed(_, let changes) where !force && !changes.isEmpty:
                throw modified(destination, changes: changes, action: "install")
            default: break
            }

            let staged = parent.appendingPathComponent(".\(name).new-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staged) }
            try manager.copyItem(at: source, to: staged)
            let files = try files(in: staged)
            let record = Record(skill: name, version: version, source: source.path, files: files)
            let marker = staged.appendingPathComponent(recordName)
            if try fileType(marker) != nil { try manager.removeItem(at: marker) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: marker, options: .atomic)

            if case .absent = state {
                try atomicRename(staged, to: destination, flags: UInt32(RENAME_EXCL))
            } else {
                try atomicRename(staged, to: destination, flags: UInt32(RENAME_SWAP))
                try manager.removeItem(at: staged)
            }
        }
    }

    static func uninstall(from destination: URL, force: Bool) throws -> Bool {
        let parent = destination.deletingLastPathComponent()
        guard try fileType(parent) != nil else { return false }
        return try withDirectoryLock(parent) {
            switch try inspect(destination) {
            case .absent: return false
            case .foreign:
                throw SkillError("\(destination.path) was not installed by swift-ember")
            case .managed(_, let changes):
                if !force && !changes.isEmpty { throw modified(destination, changes: changes, action: "uninstall") }
                let removed = parent.appendingPathComponent(".\(name).removed-\(UUID().uuidString)")
                try atomicRename(destination, to: removed, flags: UInt32(RENAME_EXCL))
                try FileManager.default.removeItem(at: removed)
                return true
            }
        }
    }

    private static func modified(_ destination: URL, changes: [String], action: String) -> SkillError {
        SkillError("\(destination.path) has local changes:\n  \(changes.joined(separator: "\n  "))\n"
            + "Rerun skill \(action) with --force to discard them.")
    }

    private static func atomicRename(_ source: URL, to destination: URL, flags: UInt32) throws {
        guard renamex_np(source.path, destination.path, flags) == 0 else {
            throw SkillError("cannot move \(source.path) to \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    // Install and uninstall share the destination parent's lock. Using the directory inode
    // also makes it unnecessary to leave a lock file in the user's skills directory.
    private static func withDirectoryLock<T>(_ directory: URL, operation: () throws -> T) throws -> T {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SkillError("cannot open skills directory \(directory.path): errno \(errno)") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SkillError("cannot lock skills directory \(directory.path): errno \(errno)") }
        }
        return try operation()
    }
}
