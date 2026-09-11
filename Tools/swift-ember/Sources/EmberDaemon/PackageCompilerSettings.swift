import Foundation

/// SwiftPM target settings that affect how a package source body is parsed and
/// type-checked. Using the application's flags for a package can silently take
/// a different `#if` branch, so an unreadable setting fails closed.
enum PackageCompilerSettings: Sendable {
    case flags([String])
    case unknown(String)

    private enum LanguageModeResult {
        case mode(String)
        case unknown(String)
    }

    private struct ToolsVersion: Comparable {
        let major: Int
        let minor: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }
    }

    static func read(
        module: String,
        manifest: URL,
        swiftCompilerPath: String,
        sdkName: String,
        cacheDirectory: URL
    ) -> PackageCompilerSettings {
        let automatic = ["-D", "SWIFT_PACKAGE", "-D", "DEBUG"]
        guard let manifestSource = try? String(contentsOf: manifest, encoding: .utf8) else {
            return .unknown("could not read \(manifest.lastPathComponent)")
        }
        // With no package- or target-level language/settings arguments, the
        // tools version is the complete answer and does not require launching
        // SwiftPM. Apart from making the common case cheap, this keeps the
        // result available when only the build's compiler driver is retained.
        let requiresEvaluation = [
            "swiftSettings", "swiftLanguageModes", "swiftLanguageVersions", "resources",
        ].contains { manifestSource.contains($0) }
        if !requiresEvaluation {
            switch PackageLanguageMode.read(from: manifest) {
            case .mode(let mode):
                guard let toolsVersion = toolsVersion(inManifestSource: manifestSource) else {
                    return .unknown("its manifest's swift-tools-version could not be read")
                }
                return .flags(automatic + resourceBundleFlags(hasResources: false) + derivedFlags(
                    toolsVersion: toolsVersion, languageMode: mode,
                    packageIdentity: packageIdentity(for: manifest)))
            case .unknown(let reason): return .unknown(reason)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            let swift = URL(fileURLWithPath: swiftCompilerPath)
                .deletingLastPathComponent().appendingPathComponent("swift")
            guard FileManager.default.isExecutableFile(atPath: swift.path) else {
                return .unknown("could not locate swift next to the selected compiler")
            }
            var environment = ProcessInfo.processInfo.environment
            environment["CLANG_MODULE_CACHE_PATH"] = cacheDirectory.path
            environment["SWIFTPM_MODULECACHE_OVERRIDE"] = cacheDirectory.path
            let result = try Subprocess.runSeparated(
                swift.path,
                arguments: [
                    "package", "--disable-sandbox", "dump-package",
                    "--package-path", manifest.deletingLastPathComponent().path,
                ],
                environment: environment)
            guard result.exitCode == 0 else {
                let reason = result.standardError
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .unknown("could not evaluate \(manifest.lastPathComponent): \(reason)")
            }
            switch decode(
                Data(result.standardOutput.utf8), module: module,
                platform: packagePlatform(for: sdkName),
                packageIdentity: packageIdentity(for: manifest)) {
            case .flags(let flags): return .flags(automatic + flags)
            case .unknown(let reason): return .unknown(reason)
            }
        } catch {
            return .unknown("could not evaluate \(manifest.lastPathComponent): \(error)")
        }
    }

    static func decode(_ data: Data, module: String, platform: String,
                       packageIdentity: String? = nil) -> PackageCompilerSettings {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = root["targets"] as? [[String: Any]],
              let target = targets.first(where: { $0["name"] as? String == module }),
              let settings = target["settings"] as? [[String: Any]] else {
            return .unknown("the package description contains no target named \(module)")
        }

        let resources = target["resources"] as? [Any]
        var flags = resourceBundleFlags(hasResources: resources?.isEmpty == false)
        var languageMode: String?
        for setting in settings where setting["tool"] as? String == "swift" {
            if let condition = setting["condition"] as? [String: Any] {
                if let traits = condition["traits"] as? [String], !traits.isEmpty {
                    return .unknown("\(module) uses package traits that the build context does not identify")
                }
                if let configuration = condition["config"] as? String,
                   configuration != "debug" {
                    continue
                }
                if let platforms = condition["platformNames"] as? [String],
                   !platforms.isEmpty, !platforms.contains(platform) {
                    continue
                }
            }
            guard let kind = setting["kind"] as? [String: Any], kind.count == 1,
                  let (name, rawPayload) = kind.first,
                  let payload = rawPayload as? [String: Any] else {
                return .unknown("\(module) has an unreadable Swift target setting")
            }
            switch name {
            case "define":
                guard let value = payload["_0"] as? String else {
                    return .unknown("\(module) has an unreadable Swift define")
                }
                flags += ["-D", value]
            case "unsafeFlags":
                guard let values = payload["_0"] as? [String] else {
                    return .unknown("\(module) has unreadable Swift unsafe flags")
                }
                flags += values
            case "enableUpcomingFeature":
                guard let value = payload["_0"] as? String else {
                    return .unknown("\(module) has an unreadable upcoming feature")
                }
                flags += ["-enable-upcoming-feature", value]
            case "enableExperimentalFeature":
                guard let value = payload["_0"] as? String else {
                    return .unknown("\(module) has an unreadable experimental feature")
                }
                flags += ["-enable-experimental-feature", value]
            case "swiftLanguageMode":
                guard let value = payload["_0"] as? String else {
                    return .unknown("\(module) has an unreadable Swift language mode")
                }
                guard languageMode == nil || languageMode == value else {
                    return .unknown("\(module) has more than one applicable Swift language mode")
                }
                languageMode = value
            default:
                return .unknown("\(module) uses unsupported Swift target setting \(name)")
            }
        }
        if languageMode == nil {
            switch defaultLanguageMode(in: root) {
            case .mode(let mode): languageMode = mode
            case .unknown(let reason): return .unknown(reason)
            }
        }
        guard let languageMode,
              let toolsVersion = toolsVersion(inDescription: root) else {
            return .unknown("the package description has no readable tools version")
        }
        flags += derivedFlags(
            toolsVersion: toolsVersion, languageMode: languageMode,
            packageIdentity: packageIdentity)
        return .flags(flags)
    }

    private static func defaultLanguageMode(
        in root: [String: Any]
    ) -> LanguageModeResult {
        if let versions = root["swiftLanguageVersions"] as? [String], !versions.isEmpty {
            guard Set(versions).count == 1, let version = versions.first else {
                return .unknown(
                    "the package declares several Swift language modes and its selected mode is unavailable")
            }
            return .mode(version)
        }
        guard let tools = root["toolsVersion"] as? [String: Any],
              let version = tools["_version"] as? String,
              let major = Int(version.split(separator: ".").first ?? "") else {
            return .unknown("the package description has no readable tools version")
        }
        guard major >= 5 else {
            return .unknown("the package uses Swift tools \(version), which is not supported")
        }
        return .mode(major >= 6 ? "6" : "5")
    }

    /// SwiftPM adds these independently of a target's `swiftSettings`. They
    /// affect whether otherwise valid source can even be parsed or whether a
    /// `package` declaration is accessible from the generated patch module.
    private static func derivedFlags(
        toolsVersion: ToolsVersion,
        languageMode: String,
        packageIdentity: String?
    ) -> [String] {
        var flags: [String] = []
        if languageMode == "5", toolsVersion >= ToolsVersion(major: 5, minor: 7) {
            flags.append("-enable-bare-slash-regex")
        }
        flags += ["-swift-version", languageMode]
        if toolsVersion >= ToolsVersion(major: 5, minor: 9),
           let packageIdentity, !packageIdentity.isEmpty {
            flags += ["-package-name", packageIdentity]
        }
        return flags
    }

    /// SwiftPM exposes whether `Bundle.module` was generated through one of
    /// these mutually exclusive defines. Source using the same condition must
    /// take the same branch when compiled as a patch.
    private static func resourceBundleFlags(hasResources: Bool) -> [String] {
        ["-D", hasResources
            ? "SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE"
            : "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE"]
    }

    private static func toolsVersion(inDescription root: [String: Any]) -> ToolsVersion? {
        guard let tools = root["toolsVersion"] as? [String: Any],
              let value = tools["_version"] as? String else { return nil }
        return toolsVersion(in: value)
    }

    private static func toolsVersion(inManifestSource source: String) -> ToolsVersion? {
        guard let line = source.split(separator: "\n").first(where: {
            $0.lowercased().contains("swift-tools-version")
        }) else { return nil }
        let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return toolsVersion(in: String(digits))
    }

    private static func toolsVersion(in value: String) -> ToolsVersion? {
        let components = value.split(separator: ".")
        guard let first = components.first, let major = Int(first) else { return nil }
        let minor = components.dropFirst().first.flatMap { Int($0) } ?? 0
        return ToolsVersion(major: major, minor: minor)
    }

    /// SwiftPM uses the local package identity, derived from the package
    /// directory rather than `Package(name:)`, and mangles it into a compiler
    /// identifier (`swift-splice` becomes `swift_splice`).
    private static func packageIdentity(for manifest: URL) -> String {
        manifest.deletingLastPathComponent().lastPathComponent.lowercased().map {
            $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    private static func packagePlatform(for sdkName: String) -> String {
        switch sdkName.lowercased() {
        case "iphoneos", "iphonesimulator": "ios"
        case "macosx": "macos"
        default: sdkName.lowercased()
        }
    }
}
