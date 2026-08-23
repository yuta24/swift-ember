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
                                  recovery: .rebuild)
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
        let triple = try targetTriple(from: settings)

        // Compilation conditions have to reach the patch compile too, or a
        // `#if` inside a patched body takes the other branch.
        let conditions = (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .flatMap { ["-D", String($0)] }

        let context = BuildContext(
            moduleName: module,
            swiftCompilerPath: try which("swiftc"),
            swiftCompilerVersion: try compilerVersion(),
            targetTriple: triple,
            sdkPath: try require("SDKROOT"),
            sdkName: settings["PLATFORM_NAME"] ?? "iphonesimulator",
            appBinaryPath: builtProducts + "/" + executablePath,
            // The application's own .swiftmodule is what a patch imports.
            moduleSearchPaths: [builtProducts, builtProducts + "/\(module).swiftmodule"],
            extraCompilerFlags: conditions,
            sourceRoots: sourceRoots.isEmpty ? [try require("SRCROOT")] : sourceRoots,
            bundleIdentifier: try require("PRODUCT_BUNDLE_IDENTIFIER"))

        return Resolved(context: context, settings: settings)
    }

    // MARK: - xcodebuild

    private func readSettings() throws -> [String: String] {
        var arguments = ["xcodebuild"] + container.arguments
        arguments += ["-scheme", scheme,
                      "-configuration", configuration,
                      "-destination", destination,
                      "-showBuildSettings", "-json"]

        let result = try Subprocess.run("/usr/bin/xcrun", arguments: arguments)
        guard result.exitCode == 0 else {
            throw SpliceError(stage: .watch, subject: scheme,
                              reason: "xcodebuild could not resolve the build settings:\n"
                                + result.combinedOutput.split(separator: "\n").suffix(15).joined(separator: "\n"),
                              recovery: .rebuild)
        }

        // xcodebuild prints warnings before the JSON, so start at the array.
        guard let start = result.combinedOutput.firstIndex(of: "["),
              let data = String(result.combinedOutput[start...]).data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw SpliceError(stage: .watch, subject: scheme,
                              reason: "could not read xcodebuild's JSON output",
                              recovery: .rebuild)
        }

        // With several targets in the scheme the application is the one that
        // produces an executable.
        let applications = entries.compactMap { $0["buildSettings"] as? [String: Any] }
            .filter { ($0["WRAPPER_EXTENSION"] as? String) == "app" }
        guard let chosen = applications.first ?? entries.first?["buildSettings"] as? [String: Any] else {
            throw SpliceError(stage: .watch, subject: scheme,
                              reason: "scheme '\(scheme)' does not build an application",
                              recovery: .rebuild)
        }
        return chosen.compactMapValues { $0 as? String }
    }

    private func targetTriple(from settings: [String: String]) throws -> String {
        let arch = settings["NATIVE_ARCH"]
            ?? settings["CURRENT_ARCH"]
            ?? settings["ARCHS"]?.split(separator: " ").first.map(String.init)
            ?? "arm64"
        let platform = settings["PLATFORM_NAME"] ?? "iphonesimulator"
        let deployment = settings["IPHONEOS_DEPLOYMENT_TARGET"]
            ?? settings["MACOSX_DEPLOYMENT_TARGET"]
            ?? "17.0"

        return switch platform {
        case "iphonesimulator": "\(arch)-apple-ios\(deployment)-simulator"
        case "iphoneos": "\(arch)-apple-ios\(deployment)"
        case "macosx": "\(arch)-apple-macosx\(deployment)"
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
