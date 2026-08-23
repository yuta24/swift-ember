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
    public var extraCompilerFlags: [String]
    public var sourceRoots: [String]
    /// Bundle identifier of the running application, used to find its data
    /// container on the simulator.
    public var bundleIdentifier: String

    public init(moduleName: String, swiftCompilerPath: String, swiftCompilerVersion: String,
                targetTriple: String, sdkPath: String, sdkName: String, appBinaryPath: String,
                moduleSearchPaths: [String], extraCompilerFlags: [String],
                sourceRoots: [String], bundleIdentifier: String) {
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

    /// What a patch must link against, which is not always the executable.
    ///
    /// Xcode 16 and later build Debug configurations as a thin launcher plus a
    /// `.debug.dylib` holding the actual code. The replacement keys live in the
    /// dylib; the executable has none at all, so linking a patch against it
    /// resolves nothing and `doctor` reports a correctly configured project as
    /// having no keys. Resolved on each use rather than stored, because whether
    /// the dylib exists depends on how the app was last built.
    public var linkTarget: String {
        let debugDylib = appBinaryPath + ".debug.dylib"
        return FileManager.default.fileExists(atPath: debugDylib) ? debugDylib : appBinaryPath
    }

    /// The fields section 6.3 requires to match between the running binary and
    /// a patch. Compared as one opaque string so a mismatch is one message
    /// rather than a field-by-field audit.
    public var identity: String {
        [moduleName, targetTriple, sdkName, swiftCompilerVersion].joined(separator: "|")
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
