import Foundation

enum PackageManifest {
    struct EvaluationError: Error, CustomStringConvertible {
        let description: String
    }

    static func files(beside manifest: URL) -> [URL] {
        let directory = manifest.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return [manifest] + files.filter {
            $0.lastPathComponent.hasPrefix("Package@swift-") && $0.pathExtension == "swift"
        }
    }

    static func hasVersionedManifest(beside manifest: URL) -> Bool {
        files(beside: manifest).count > 1
    }

    static func run(
        _ command: [String], manifest: URL, swiftCompilerPath: String, cacheDirectory: URL
    ) throws -> Data {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let swift = URL(fileURLWithPath: swiftCompilerPath)
            .deletingLastPathComponent().appendingPathComponent("swift")
        guard FileManager.default.isExecutableFile(atPath: swift.path) else {
            throw EvaluationError(description: "could not locate swift next to the selected compiler")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CLANG_MODULE_CACHE_PATH"] = cacheDirectory.path
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = cacheDirectory.path
        let result = try Subprocess.runSeparated(swift.path, arguments: [
            "package", "--disable-sandbox",
            "--package-path", manifest.deletingLastPathComponent().path,
            "--scratch-path", cacheDirectory.appendingPathComponent("scratch").path,
            "--cache-path", cacheDirectory.appendingPathComponent("cache").path,
            "--config-path", cacheDirectory.appendingPathComponent("config").path,
            "--security-path", cacheDirectory.appendingPathComponent("security").path,
            "--manifest-cache", "local",
        ] + command, environment: environment)
        guard result.exitCode == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EvaluationError(description: detail.isEmpty ? "SwiftPM exited with \(result.exitCode)" : detail)
        }
        return Data(result.standardOutput.utf8)
    }
}
