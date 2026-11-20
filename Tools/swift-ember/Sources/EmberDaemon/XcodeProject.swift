import Foundation
import EmberCore

/// Derives a `BuildContext` from a real Xcode project.
///
/// DESIGN.md section 6.2 asks for the actual compile invocation rather than a
/// reverse-engineered set of build settings. This asks `xcodebuild` for the
/// resolved settings instead, which is a deliberate departure and worth saying
/// why: scraping a build log for the `swift-frontend` line means requiring a
/// full build, parsing output with no compatibility promise, and getting
/// nothing at all when the build is up to date. `-showBuildSettings -json` is a
/// supported interface, needs no build, and reports what Xcode itself resolved
/// rather than what this tool guessed. A Scheme Build action uses the app
/// target's exported settings directly, including overrides from the build
/// that just ran.
///
/// The reason section 6.2 wanted the invocation was to avoid guessing. That
/// concern is met a different way: nothing derived here is trusted on its own.
/// `doctor` reads the built binary back and checks it actually exports
/// replacement keys, which is the only evidence that matters.
public struct XcodeProject: Sendable {
    public enum Container: Sendable {
        case project(String)
        case workspace(String)

        var arguments: [String] {
            switch self {
            case .project(let path): ["-project", path]
            case .workspace(let path): ["-workspace", path]
            }
        }

        var environmentLocation: (key: String, path: String) {
            switch self {
            case .project(let path): ("PROJECT_FILE_PATH", path)
            case .workspace(let path): ("WORKSPACE_PATH", path)
            }
        }
    }

    public let container: Container
    public let scheme: String
    public let configuration: String
    public let destination: String
    public let deviceIdentifier: String?
    public let simulatorIdentifier: String?
    public let derivedDataPath: String?

    public init(container: Container, scheme: String,
                configuration: String = "Debug",
                destination: String = "generic/platform=iOS Simulator",
                deviceIdentifier: String? = nil,
                simulatorIdentifier: String? = nil,
                derivedDataPath: String? = nil) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.deviceIdentifier = deviceIdentifier
        self.simulatorIdentifier = simulatorIdentifier
        self.derivedDataPath = derivedDataPath
        self.destination = (deviceIdentifier ?? simulatorIdentifier).map { "id=\($0)" } ?? destination
    }

    /// Everything `doctor` needs to explain a misconfiguration, kept separate
    /// from `BuildContext` because a context that cannot be built is still
    /// worth reporting on.
    public struct Resolved: Sendable {
        public let context: BuildContext
        public let settings: [String: String]
        public var testabilityEnabled: Bool { settings["SWIFT_ENABLE_TESTABILITY"] == "YES" }
        public var implicitDynamicEnabled: Bool {
            (settings["OTHER_SWIFT_FLAGS"] ?? "").contains("-enable-implicit-dynamic")
        }
        public var optimisationDisabled: Bool { settings["SWIFT_OPTIMIZATION_LEVEL"] == "-Onone" }
        public var runtimeEnabled: Bool {
            (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").contains("EMBER_ENABLED")
        }
        public var declaredConfigured: Bool { settings["EMBER_CONFIGURED"] == "YES" }
    }

    public func resolve(sourceRoots: [String], excludedSourcePaths: [String] = [],
                        schemeBuildSettings: [String: String]? = nil,
                        allowsMissingSchemeBinary: Bool = false) throws -> Resolved {
        let settings = try buildSettings(schemeEnvironment: schemeBuildSettings, query: readSettings)
        let isSchemeAction = schemeBuildSettings != nil
        let products = try buildProducts(from: settings, schemeAction: isSchemeAction)
        if isSchemeAction, !allowsMissingSchemeBinary,
           !FileManager.default.fileExists(atPath: products.linkTarget) {
            throw schemeError("the build post-action's binary is missing at \(products.linkTarget). Build the selected app target before recording sources or starting the watcher.",
                              recovery: .rebuild)
        }

        func require(_ key: String) throws -> String {
            try requiredSetting(key, in: settings, schemeAction: isSchemeAction)
        }

        let module = try settings["PRODUCT_MODULE_NAME"] ?? require("PRODUCT_NAME")

        // Xcode reports SDK name and version separately; the triple has to be
        // assembled from the architecture, the platform, and the deployment
        // target, which is the one place here that is genuinely a derivation
        // rather than a lookup.
        let triple = try Self.targetTriple(from: settings)

        // Everything that changes how the patched body is *interpreted* has to
        // reach the patch compile. A `#if` taking the other branch is the
        // obvious one; the language mode is the dangerous one, because a body
        // written for Swift 6 and type-checked under Swift 5 loses isolation
        // inference and sendability checking, and the replacement can then
        // introduce a data race the original could not have had.
        var flags = (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .flatMap { ["-D", String($0)] }

        // Everything else the project passes to swiftc, verbatim.
        //
        // Dropped entirely until a review measured what that costs. A project
        // that puts `-DUSE_LIVE_PRICING` here -- the second most obvious place
        // to put a compilation condition, and the same file this tool asks
        // projects to base Debug on -- had `#if USE_LIVE_PRICING` take the
        // other branch in every patch, silently. `-enable-bare-slash-regex`,
        // which Xcode passes as a matter of course, made every body containing
        // a regex literal fail to compile with "'/' is not a prefix unary
        // operator" against generated source the developer never wrote.
        //
        // The two flags this tool asks for itself are in here too and are
        // harmless on a patch: implicit dynamic makes the patch's own
        // declarations replaceable, which nothing looks at, and private imports
        // is about the module being imported.
        flags += Self.parseSettingList(settings["OTHER_SWIFT_FLAGS"])

        // `EFFECTIVE_SWIFT_VERSION` is what Xcode resolved and is already in
        // the form the compiler accepts. `SWIFT_VERSION` is the raw setting:
        // Xcode says "5.0" and "6.0" where the compiler accepts only 4, 4.2, 5
        // and 6, and passing it through verbatim failed every patch compile
        // with "invalid value '5.0'". The hand-normalisation below is the
        // fallback, and it is wrong for anything not ending in `.0` -- which is
        // why the resolved value is preferred over reimplementing it.
        if let effective = settings["EFFECTIVE_SWIFT_VERSION"], !effective.isEmpty {
            flags += ["-swift-version", effective]
        } else if let version = settings["SWIFT_VERSION"], !version.isEmpty {
            let normalised = version.hasSuffix(".0") ? String(version.dropLast(2)) : version
            flags += ["-swift-version", normalised]
        }
        if let strictness = settings["SWIFT_STRICT_CONCURRENCY"], !strictness.isEmpty {
            flags += ["-strict-concurrency=\(strictness)"]
        }
        for (key, value) in settings.sorted(by: { $0.key < $1.key })
        where key.hasPrefix("SWIFT_UPCOMING_FEATURE_") && value == "YES" {
            // The setting's suffix is not the feature's name. Xcode turns
            // `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY` into
            // `-enable-upcoming-feature ExistentialAny`; passing the suffix
            // through gave `EXISTENTIAL_ANY`, and swiftc accepts an unknown
            // feature name in silence -- so this forwarded nothing at all, for
            // every feature, without a word about it.
            flags += ["-enable-upcoming-feature",
                      Self.featureName(fromSettingSuffix:
                        key.replacingOccurrences(of: "SWIFT_UPCOMING_FEATURE_", with: ""))]
        }

        // Scheme actions can export an SDK name in SDKROOT and the resolved
        // directory separately in SDK_DIR. swiftc's -sdk needs the directory.
        let sdkRoot = try require("SDKROOT")
        let sdkPath = if sdkRoot.hasPrefix("/") { sdkRoot } else { try require("SDK_DIR") }
        guard sdkPath.hasPrefix("/") else {
            throw schemeError("Xcode did not report an absolute SDK directory for SDKROOT '\(sdkRoot)'.")
        }
        let roots = sourceRoots.isEmpty ? [try require("SRCROOT")] : sourceRoots
        let context = BuildContext(
            moduleName: module,
            swiftCompilerPath: try which("swiftc"),
            swiftCompilerVersion: try compilerVersion(),
            targetTriple: triple,
            sdkPath: sdkPath,
            sdkName: settings["PLATFORM_NAME"] ?? "iphonesimulator",
            appBinaryPath: products.executable,
            // The application's own .swiftmodule is what a patch imports.
            moduleSearchPaths: [products.directory, products.directory + "/\(module).swiftmodule"]
                + Self.parseSearchPaths(settings["SWIFT_INCLUDE_PATHS"]),
            extraCompilerFlags: flags,
            sourceRoots: roots,
            bundleIdentifier: try require("PRODUCT_BUNDLE_IDENTIFIER"),
            debugDylibPath: products.debugDylib,
            // Without these, copying an import of a framework the app finds by
            // -F turns every patch from that file into "no such module".
            frameworkSearchPaths: [products.directory]
                + Self.parseSearchPaths(settings["FRAMEWORK_SEARCH_PATHS"]),
            deviceIdentifier: deviceIdentifier,
            simulatorIdentifier: simulatorIdentifier,
            codeSigningIdentity: Self.signingIdentity(from: settings),
            excludedSourcePaths: excludedSourcePaths,
            buildOutputPaths: buildOutputPaths(from: settings, sourceRoots: roots))

        return Resolved(context: context, settings: settings)
    }

    func buildOutputPaths(from settings: [String: String], sourceRoots: [String]) -> [String] {
        func directory(_ path: String?) -> URL? {
            guard let path, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        let outputSettings = [
            "BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "BUILD_DIR", "SYMROOT", "OBJROOT",
            "PROJECT_TEMP_DIR", "TARGET_TEMP_DIR", "DERIVED_FILE_DIR", "DERIVED_SOURCES_DIR",
        ]
        var outputs = outputSettings.compactMap { directory(settings[$0]) }
        var derivedData = [directory(derivedDataPath), directory(settings["DERIVED_DATA_DIR"])].compactMap { $0 }
        // Older settings may expose only the standard layout's products and
        // intermediates. Both are needed to recognize their common parent.
        if derivedData.isEmpty, let intermediates = directory(settings["OBJROOT"]),
           intermediates.lastPathComponent == "Intermediates.noindex" {
            let build = intermediates.deletingLastPathComponent()
            let products = SourcePathFilter(excluding: [build.appendingPathComponent("Products")])
            if build.lastPathComponent == "Build",
               let builtProducts = directory(settings["BUILT_PRODUCTS_DIR"]), products.excludes(builtProducts) {
                derivedData.append(build.deletingLastPathComponent())
            }
        }
        outputs += derivedData
        outputs += derivedData.map { $0.appendingPathComponent("SourcePackages", isDirectory: true) }

        let roots = sourceRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let sourceTree = SourcePathFilter(excluding: roots)
        let projectRoot = directory(settings["SRCROOT"])
        var result: [URL] = []
        for output in outputs.sorted(by: { $0.path < $1.path }) {
            let subtree = SourcePathFilter(excluding: [output])
            // Some custom settings put products alongside source files.
            // Never use the project directory itself as an exclusion.
            if let projectRoot, subtree.excludes(projectRoot) { continue }
            guard sourceTree.excludes(output) || roots.contains(where: subtree.excludes),
                  !SourcePathFilter(excluding: result).excludes(output) else { continue }
            result.append(output)
        }
        return result.map(\.path)
    }

    func buildSettings(schemeEnvironment: [String: String]?,
                       query: () throws -> [String: String]) throws -> [String: String] {
        guard let settings = schemeEnvironment else { return try query() }
        guard settings["WRAPPER_EXTENSION"] == "app" else {
            throw schemeError("the Scheme Build action needs settings from the app target. Select it under 'Provide build settings from' in the Build pre-action or post-action.")
        }

        let (key, configuredPath) = container.environmentLocation
        if let actionPath = settings[key], !actionPath.isEmpty,
           Self.canonicalPath(actionPath) != Self.canonicalPath(configuredPath) {
            throw schemeError("\(key) from the Scheme Build action is '\(actionPath)', but the configured container is '\(configuredPath)'. Check the Scheme's app target and swift-ember's project or workspace.")
        }
        let platform = try requiredSetting("PLATFORM_NAME", in: settings, schemeAction: true)
        if (deviceIdentifier != nil && platform != "iphoneos")
            || (simulatorIdentifier != nil && platform != "iphonesimulator") {
            throw schemeError("the requested destination disagrees with the Scheme Build action's PLATFORM_NAME (\(platform)). Check --device or --simulator.")
        }

        if let derivedDataPath {
            let action = try buildProducts(from: settings, schemeAction: true)
            let queried = try buildProducts(from: query(), schemeAction: false)
            guard Self.canonicalPath(action.linkTarget) == Self.canonicalPath(queried.linkTarget),
                  Self.canonicalPath(action.directory) == Self.canonicalPath(queried.directory) else {
                throw schemeError("""
                    --derived-data-path '\(derivedDataPath)' disagrees with the Scheme Build action's output.
                    Scheme action: \(action.linkTarget) (products: \(action.directory))
                    xcodebuild:    \(queried.linkTarget) (products: \(queried.directory))
                    Use the path passed to the original xcodebuild or omit --derived-data-path in the Scheme Build action.
                    """)
            }
        }
        return settings
    }

    struct Products {
        let directory: String
        let executable: String
        let debugDylib: String?
        var linkTarget: String { debugDylib ?? executable }
    }

    func buildProducts(from settings: [String: String], schemeAction: Bool) throws -> Products {
        let directory = try requiredSetting("BUILT_PRODUCTS_DIR", in: settings, schemeAction: schemeAction)
        let executablePath = try requiredSetting("EXECUTABLE_PATH", in: settings, schemeAction: schemeAction)
        // TARGET_BUILD_DIR contains the app itself. BUILT_PRODUCTS_DIR is
        // still the place to search for modules and frameworks.
        let targetDirectory = settings["TARGET_BUILD_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? directory
        guard directory.hasPrefix("/"), targetDirectory.hasPrefix("/"),
              !executablePath.hasPrefix("/"), !executablePath.split(separator: "/").contains("..") else {
            throw schemeError("invalid Xcode product paths: BUILT_PRODUCTS_DIR='\(directory)', TARGET_BUILD_DIR='\(targetDirectory)', EXECUTABLE_PATH='\(executablePath)'.")
        }
        let executable = URL(fileURLWithPath: targetDirectory, isDirectory: true)
            .appendingPathComponent(executablePath).standardizedFileURL.path
        // A dylib may still exist from an earlier build that enabled it.
        let debugDylib = settings["ENABLE_DEBUG_DYLIB"] == "YES" ? executable + ".debug.dylib" : nil
        return Products(directory: directory, executable: executable, debugDylib: debugDylib)
    }

    private func requiredSetting(_ key: String, in settings: [String: String],
                                 schemeAction: Bool) throws -> String {
        guard let value = settings[key], !value.isEmpty else {
            let reason = schemeAction
                ? "the Scheme Build action did not provide \(key). Select the app target under 'Provide build settings from'."
                : "xcodebuild did not report \(key) for scheme '\(scheme)'"
            throw schemeError(reason)
        }
        return value
    }

    private func schemeError(_ reason: String, recovery: EmberError.Recovery = .configure) -> EmberError {
        EmberError(stage: .watch, subject: scheme, reason: reason, recovery: recovery)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func signingIdentity(from settings: [String: String]) -> String? {
        for key in ["EXPANDED_CODE_SIGN_IDENTITY", "CODE_SIGN_IDENTITY"] {
            guard let value = settings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != "-" else { continue }
            return value
        }
        return nil
    }

    /// Splits a resolved Xcode list setting. Swift Build separates on unquoted
    /// ASCII whitespace and treats a backslash as escaping the next character
    /// even inside single or double quotes.
    package static func parseSettingList(_ value: String?) -> [String] {
        guard let value else { return [] }

        var arguments: [String] = []
        var argument = ""
        var hasArgument = false
        var quote: Unicode.Scalar?
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if quote == nil, scalar == " " || ("\t"..."\r").contains(scalar) {
                if hasArgument {
                    arguments.append(argument)
                    argument = ""
                    hasArgument = false
                }
                continue
            }

            // Even an empty quoted string is an argument.
            hasArgument = true
            switch scalar {
            case "\\":
                argument.unicodeScalars.append(scalars.next() ?? scalar)
            case "\"", "'":
                if quote == scalar {
                    quote = nil
                } else if quote == nil {
                    quote = scalar
                } else {
                    argument.unicodeScalars.append(scalar)
                }
            default:
                argument.unicodeScalars.append(scalar)
            }
        }
        if hasArgument { arguments.append(argument) }
        return arguments
    }

    static func parseSearchPaths(_ value: String?) -> [String] {
        parseSettingList(value).filter { !$0.isEmpty }.flatMap(expandingRecursive)
    }

    /// `/**` means "and every directory under it" to Xcode, which enumerates
    /// them and passes one `-F` each.
    ///
    /// Trimming it to the top directory was this parser's earlier answer, on the
    /// grounds that `swiftc` has no such notation. It does not: a framework in a
    /// subdirectory is importable in the app and "no such module" in a patch.
    static func expandingRecursive(_ path: String) -> [String] {
        guard path.hasSuffix("/**") else { return [path] }
        let root = String(path.dropLast(3))
        var found = [root]
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: URL(fileURLWithPath: root),
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return found }
        for case let url as URL in walker
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            found.append(url.path)
        }
        return found
    }

    /// `EXISTENTIAL_ANY` -> `ExistentialAny`.
    static func featureName(fromSettingSuffix suffix: String) -> String {
        suffix.split(separator: "_").map { word in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined()
    }

    // MARK: - xcodebuild

    var buildSettingsArguments: [String] {
        var arguments = ["xcodebuild"] + container.arguments
        arguments += ["-scheme", scheme,
                      "-configuration", configuration,
                      "-destination", destination,
                      "-showBuildSettings", "-json"]
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath] }
        return arguments
    }

    private func readSettings() throws -> [String: String] {
        // Separate pipes. Merging them and hunting for the first bracket found
        // the one inside `2026-08-24 08:54:10.308 xcodebuild[27960:9171152]`,
        // and any stray notice on stderr made a healthy project unreadable.
        let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: buildSettingsArguments)
        guard result.exitCode == 0 else {
            // Both streams and the status. A corrupted project file makes
            // xcodebuild die on a signal with zero bytes on either stream, and
            // interpolating stderr alone printed a heading, two blank lines and
            // nothing else.
            let detail = [result.standardError, result.standardOutput]
                .map { $0.split(separator: "\n").suffix(10).joined(separator: "\n") }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw EmberError(
                stage: .watch, subject: scheme,
                reason: "xcodebuild exited with \(result.exitCode) and could not resolve the build settings"
                    + (detail.isEmpty ? ", saying nothing" : ":\n" + detail),
                recovery: .configure)
        }

        // xcodebuild still prefixes stdout with its own notices, so find the
        // line the array starts on rather than the first bracket anywhere.
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        guard let arrayStart = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[" }),
              let data = lines[arrayStart...].joined(separator: "\n").data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw EmberError(stage: .watch, subject: scheme,
                              reason: "could not read xcodebuild's JSON output",
                              recovery: .rebuild)
        }

        // With several targets in the scheme the application is the one that
        // produces an app wrapper. Falling back to "whatever came first" meant
        // a framework-only scheme yielded that framework's module name and
        // bundle identifier, and the mistake surfaced much later as an
        // unrelated container or link failure.
        let applications = entries.compactMap { $0["buildSettings"] as? [String: Any] }
            .filter { ($0["WRAPPER_EXTENSION"] as? String) == "app" }

        guard !applications.isEmpty else {
            throw EmberError(stage: .watch, subject: scheme,
                              reason: "scheme '\(scheme)' does not build an application",
                              recovery: .rebuild)
        }
        guard applications.count == 1 else {
            let names = applications.compactMap { $0["PRODUCT_NAME"] as? String }.sorted()
            throw EmberError(
                stage: .watch, subject: scheme,
                reason: """
                    scheme '\(scheme)' builds more than one application \
                    (\(names.joined(separator: ", "))), so there is no single binary to \
                    patch against.

                    An app with an App Clip or a watch app is Xcode's own default shape, \
                    so this may need a scheme of your own that builds only the app you \
                    are running.
                    """,
                recovery: .configure)
        }
        return applications[0].compactMapValues { $0 as? String }
    }

    static func targetTriple(from settings: [String: String]) throws -> String {
        // CURRENT_ARCH resolves to the literal "undefined_arch" outside a real
        // build, so it is not in this chain.
        // NATIVE_ARCH is the *host's* architecture, which a build need not
        // include: a project pinned to x86_64 on an arm64 machine reports
        // arm64 here and links a patch for a slice the process is not running.
        // Only trusted when the build actually names it.
        let architectures = (settings["ARCHS"] ?? "").split(separator: " ").map(String.init)
        let native = settings["NATIVE_ARCH"]
        let arch = (native.map { architectures.isEmpty || architectures.contains($0) } ?? false)
            ? native!
            : (architectures.first ?? native ?? "arm64")
        let platform = settings["PLATFORM_NAME"] ?? "iphonesimulator"

        // Projects routinely define deployment targets for several platforms
        // at once, so the right one has to be chosen by platform rather than
        // by whichever key happens to exist.
        func deployment(_ key: String, default fallback: String) throws -> String {
            guard let value = settings[key], !value.isEmpty else { return fallback }
            return value
        }

        return switch platform {
        case "iphonesimulator":
            "\(arch)-apple-ios\(try deployment("IPHONEOS_DEPLOYMENT_TARGET", default: "16.0"))-simulator"
        case "iphoneos":
            "\(arch)-apple-ios\(try deployment("IPHONEOS_DEPLOYMENT_TARGET", default: "16.0"))"
        case "macosx":
            "\(arch)-apple-macosx\(try deployment("MACOSX_DEPLOYMENT_TARGET", default: "14.0"))"
        default:
            throw EmberError(stage: .watch, subject: platform,
                              reason: "only the iOS Simulator is supported in v0.x (PRD.md section 11); this scheme builds for \(platform)",
                              recovery: .rebuild)
        }
    }

    private func which(_ tool: String) throws -> String {
        let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: ["--find", tool])
        return try Self.toolPath(tool, from: result)
    }

    /// `xcrun` can print warnings inherited from Xcode's build environment to
    /// stderr even when lookup succeeds. Keeping those warnings out of the
    /// pathname matters: `Process.executableURL` otherwise receives the warning
    /// followed by the real path and reports that `swiftc` does not exist.
    static func toolPath(_ tool: String, from result: Subprocess.SeparatedResult) throws -> String {
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0,
              !path.isEmpty,
              path.first == "/",
              !path.contains("\n"),
              FileManager.default.isExecutableFile(atPath: path) else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EmberError(stage: .watch, subject: tool,
                              reason: "xcrun could not find an executable \(tool)"
                                + (detail.isEmpty ? "" : ":\n\(detail)"),
                              recovery: .rebuild)
        }
        return path
    }

    private func compilerVersion() throws -> String {
        let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: ["swiftc", "--version"])
        guard result.exitCode == 0 else { return "unknown" }
        return result.standardOutput.split(separator: "\n").first.map(String.init) ?? "unknown"
    }
}
