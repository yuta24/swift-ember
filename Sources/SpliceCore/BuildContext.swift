import Foundation

/// The subset of DESIGN.md section 6.1 that M2 actually needs, plus the
/// identity fields section 6.3 validates before a patch is applied.
///
/// M2 reads this from a manifest the application's build emits. Recovering it
/// from an Xcode build instead is section 6.2's problem; the shape here is
/// meant to survive that change.
public struct BuildContext: Codable, Sendable {
    public var moduleName: String
    public var swiftCompilerPath: String
    public var swiftCompilerVersion: String
    public var targetTriple: String
    public var sdkPath: String
    public var sdkName: String
    public var appBinaryPath: String
    public var moduleSearchPaths: [String]
    public var frameworkSearchPaths: [String] = []
    public var extraCompilerFlags: [String]
    public var sourceRoots: [String]
    /// Bundle identifier of the running application, used to find its data
    /// container on the simulator.
    public var bundleIdentifier: String

    public init(moduleName: String, swiftCompilerPath: String, swiftCompilerVersion: String,
                targetTriple: String, sdkPath: String, sdkName: String, appBinaryPath: String,
                moduleSearchPaths: [String], extraCompilerFlags: [String],
                sourceRoots: [String], bundleIdentifier: String,
                debugDylibPath: String? = nil, frameworkSearchPaths: [String] = []) {
        self.debugDylibPath = debugDylibPath
        self.frameworkSearchPaths = frameworkSearchPaths
        self.moduleName = moduleName
        self.swiftCompilerPath = swiftCompilerPath
        self.swiftCompilerVersion = swiftCompilerVersion
        self.targetTriple = targetTriple
        self.sdkPath = sdkPath
        self.sdkName = sdkName
        self.appBinaryPath = appBinaryPath
        self.moduleSearchPaths = moduleSearchPaths
        self.extraCompilerFlags = extraCompilerFlags
        self.sourceRoots = sourceRoots
        self.bundleIdentifier = bundleIdentifier
    }

    /// What a patch must link against, when that is not the executable.
    ///
    /// Xcode 16 and later build Debug configurations as a thin launcher plus a
    /// `.debug.dylib` holding the actual code. The replacement keys live in the
    /// dylib; the executable has none at all, so linking a patch against it
    /// resolves nothing and `doctor` reports a correctly configured project as
    /// having no keys.
    ///
    /// Set from the build's own `ENABLE_DEBUG_DYLIB`, never inferred from the
    /// file being there. A dylib left behind by an earlier build is still on
    /// disk after the setting is turned off, and preferring it would be worse
    /// than useless: the patch would link against a binary the process is not
    /// running, and `dlopen` would resolve its load command by bringing a
    /// second copy of the whole app module into the live process. Replacements
    /// would bind into the copy, the running code would be untouched, and the
    /// tool would report success.
    public var debugDylibPath: String?

    /// The binary a patch links against.
    public var linkTarget: String { debugDylibPath ?? appBinaryPath }

    /// The fields section 6.3 requires to match between the running binary and
    /// a patch. Compared as one opaque string so a mismatch is one message
    /// rather than a field-by-field audit.
    public var identity: String {
        [moduleName, targetTriple, sdkName, swiftCompilerVersion].joined(separator: "|")
    }

    /// Tolerant of fields it does not know and of ones it has gained.
    ///
    /// The manifest is written by someone else's build script, so adding a
    /// property must not invalidate every file already on disk. Adding
    /// `frameworkSearchPaths` as a plain stored property did exactly that: the
    /// synthesized decoder demanded the key, every existing manifest failed to
    /// load, and the error said "no project and no build context" -- which
    /// points at the wrong thing entirely.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func required(_ key: CodingKeys) throws -> String {
            try container.decode(String.self, forKey: key)
        }
        moduleName = try required(.moduleName)
        swiftCompilerPath = try required(.swiftCompilerPath)
        swiftCompilerVersion = try required(.swiftCompilerVersion)
        targetTriple = try required(.targetTriple)
        sdkPath = try required(.sdkPath)
        sdkName = try required(.sdkName)
        appBinaryPath = try required(.appBinaryPath)
        bundleIdentifier = try required(.bundleIdentifier)
        moduleSearchPaths = try container.decodeIfPresent([String].self, forKey: .moduleSearchPaths) ?? []
        frameworkSearchPaths = try container.decodeIfPresent([String].self, forKey: .frameworkSearchPaths) ?? []
        extraCompilerFlags = try container.decodeIfPresent([String].self, forKey: .extraCompilerFlags) ?? []
        sourceRoots = try container.decodeIfPresent([String].self, forKey: .sourceRoots) ?? []
        debugDylibPath = try container.decodeIfPresent(String.self, forKey: .debugDylibPath)
    }

    public static func load(from url: URL) throws -> BuildContext {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BuildContext.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}
