import Foundation
import SpliceCore

/// Derives a `BuildContext` from a real Xcode project.
///
/// DESIGN.md section 6.2 asks for the actual compile invocation rather than a
/// reverse-engineered set of build settings. This asks `xcodebuild` for the
/// resolved settings instead, which is a deliberate departure and worth saying
/// why: scraping a build log for the `swift-frontend` line means requiring a
/// full build, parsing output with no compatibility promise, and getting
/// nothing at all when the build is up to date. `-showBuildSettings -json` is a
/// supported interface, needs no build, and reports what Xcode itself resolved
/// rather than what this tool guessed.
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
    }

    public let container: Container
    public let scheme: String
    public let configuration: String
    public let destination: String

    public init(container: Container, scheme: String,
                configuration: String = "Debug",
                destination: String = "generic/platform=iOS Simulator") {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
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
            (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").contains("SPLICE_ENABLED")
        }
        public var declaredConfigured: Bool { settings["SPLICE_CONFIGURED"] == "YES" }
    }

    public func resolve(sourceRoots: [String]) throws -> Resolved {
        let settings = try readSettings()

        func require(_ key: String) throws -> String {
            guard let value = settings[key], !value.isEmpty else {
                throw SpliceError(stage: .watch, subject: scheme,
                                  reason: "xcodebuild did not report \(key) for scheme '\(scheme)'",
                                  recovery: .configure)
            }
            return value
        }

        let module = try settings["PRODUCT_MODULE_NAME"] ?? require("PRODUCT_NAME")
        let builtProducts = try require("BUILT_PRODUCTS_DIR")
        let executablePath = try require("EXECUTABLE_PATH")

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
        flags += (settings["OTHER_SWIFT_FLAGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

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

        // Authoritative, unlike the file being present: a dylib from an
        // earlier build outlives the setting that produced it.
        let executable = builtProducts + "/" + executablePath
        let debugDylib = settings["ENABLE_DEBUG_DYLIB"] == "YES" ? executable + ".debug.dylib" : nil

        let context = BuildContext(
            moduleName: module,
            swiftCompilerPath: try which("swiftc"),
            swiftCompilerVersion: try compilerVersion(),
            targetTriple: triple,
            sdkPath: try require("SDKROOT"),
            sdkName: settings["PLATFORM_NAME"] ?? "iphonesimulator",
            appBinaryPath: executable,
            // The application's own .swiftmodule is what a patch imports.
            moduleSearchPaths: [builtProducts, builtProducts + "/\(module).swiftmodule"]
                + Self.parseSearchPaths(settings["SWIFT_INCLUDE_PATHS"]),
            extraCompilerFlags: flags,
            sourceRoots: sourceRoots.isEmpty ? [try require("SRCROOT")] : sourceRoots,
            bundleIdentifier: try require("PRODUCT_BUNDLE_IDENTIFIER"),
            debugDylibPath: debugDylib,
            // Without these, copying an import of a framework the app finds by
            // -F turns every patch from that file into "no such module".
            frameworkSearchPaths: [builtProducts]
                + Self.parseSearchPaths(settings["FRAMEWORK_SEARCH_PATHS"]))

        return Resolved(context: context, settings: settings)
    }

    /// Xcode reports search paths as one space-separated string, with any
    /// entry containing spaces quoted.
    ///
    /// Scanned rather than split on parity. `String.split` drops empty pieces,
    /// so a value beginning with a quoted path lost its leading empty piece,
    /// every index's parity flipped, and the quoted path came back shredded on
    /// its spaces. `swiftc` ignores a `-F` that does not exist, so the result
    /// was "no such module" -- the symptom these paths were added to prevent,
    /// now triggered by a space in a directory name.
    ///
    /// A trailing `/**` means "search recursively" to Xcode and nothing to
    /// `swiftc`, so it is trimmed to the directory itself rather than passed
    /// through as a path that cannot exist.
    static func parseSearchPaths(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }

        var paths: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                // Xcode escapes a quote inside a quoted path. Treating the
                // backslash as content left `quoted` toggled by the quote after
                // it, and the rest of the value -- every remaining path --
                // collapsed into one string naming a directory that does not
                // exist. `swiftc` ignores a `-F` that is not there, so the
                // symptom was "no such module", which is what this parser was
                // written to prevent.
                escaped = true
            case "\"":
                quoted.toggle()
            case " " where !quoted:
                if !current.isEmpty { paths.append(current); current = "" }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { paths.append(current) }

        return paths.flatMap(expandingRecursive)
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

    private func readSettings() throws -> [String: String] {
        var arguments = ["xcodebuild"] + container.arguments
        arguments += ["-scheme", scheme,
                      "-configuration", configuration,
                      "-destination", destination,
                      "-showBuildSettings", "-json"]

        // Separate pipes. Merging them and hunting for the first bracket found
        // the one inside `2026-08-24 08:54:10.308 xcodebuild[27960:9171152]`,
        // and any stray notice on stderr made a healthy project unreadable.
        let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: arguments)
        guard result.exitCode == 0 else {
            // Both streams and the status. A corrupted project file makes
            // xcodebuild die on a signal with zero bytes on either stream, and
            // interpolating stderr alone printed a heading, two blank lines and
            // nothing else.
            let detail = [result.standardError, result.standardOutput]
                .map { $0.split(separator: "\n").suffix(10).joined(separator: "\n") }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw SpliceError(
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
            throw SpliceError(stage: .watch, subject: scheme,
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
            throw SpliceError(stage: .watch, subject: scheme,
                              reason: "scheme '\(scheme)' does not build an application",
                              recovery: .rebuild)
        }
        guard applications.count == 1 else {
            let names = applications.compactMap { $0["PRODUCT_NAME"] as? String }.sorted()
            throw SpliceError(
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
            throw SpliceError(stage: .watch, subject: platform,
                              reason: "only the iOS Simulator is supported in v0.x (PRD.md section 11); this scheme builds for \(platform)",
                              recovery: .rebuild)
        }
    }

    private func which(_ tool: String) throws -> String {
        let result = try Subprocess.run("/usr/bin/xcrun", arguments: ["--find", tool])
        let path = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw SpliceError(stage: .watch, subject: tool,
                              reason: "xcrun could not find \(tool)", recovery: .rebuild)
        }
        return path
    }

    private func compilerVersion() throws -> String {
        let result = try Subprocess.run("/usr/bin/xcrun", arguments: ["swiftc", "--version"])
        return result.combinedOutput.split(separator: "\n").first.map(String.init) ?? "unknown"
    }
}
