import Foundation
import SpliceCore

/// Compiles generated replacement source into a loadable image, using the same
/// toolchain and configuration as the running binary (PRD.md FR-6).
public struct PatchCompiler: Sendable {
    public let context: BuildContext
    public let workDirectory: URL

    public init(context: BuildContext, workDirectory: URL) {
        self.context = context
        self.workDirectory = workDirectory
    }

    public struct Artifact: Sendable {
        public let generation: UInt64
        public let sourceURL: URL
        public let imageURL: URL
    }

    public func compile(source: String, generation: UInt64, timeline: StageTimeline) throws -> Artifact {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let name = String(format: "Patch_%03llu", generation)
        let sourceURL = workDirectory.appendingPathComponent("\(name).swift")
        let imageURL = workDirectory.appendingPathComponent("\(name).dylib")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-Onone",
            "-target", context.targetTriple,
            "-sdk", context.sdkPath,
            "-Xclang-linker", "-isysroot", "-Xclang-linker", context.sdkPath,
            "-emit-library", "-o", imageURL.path,
            "-module-name", name,
        ]
        for path in context.moduleSearchPaths { arguments += ["-I", path] }
        arguments += context.extraCompilerFlags
        arguments.append(sourceURL.path)
        // Linking against the running binary resolves the replacement keys now
        // rather than at dlopen, so an ineligible declaration fails at LINK
        // with "Undefined symbols" instead of inside the app.
        let target = context.linkTarget
        if target.hasSuffix(".dylib") {
            // An Xcode 16 debug dylib: a plain linker input, since
            // -bundle_loader only accepts an executable.
            arguments += ["-Xlinker", target]
        } else {
            arguments += ["-Xlinker", "-bundle",
                          "-Xlinker", "-bundle_loader", "-Xlinker", target]
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try Subprocess.run(context.swiftCompilerPath, arguments: arguments)

        guard result.exitCode == 0 else {
            // The linker owns the second half of this invocation, so attribute
            // the failure to whichever stage actually produced it.
            let isLink = result.combinedOutput.contains("Undefined symbols")
                || result.combinedOutput.contains("linker command failed")
            let stage: Stage = isLink ? .link : .compile
            timeline.record(stage, since: start, success: false)
            throw SpliceError(stage: stage, subject: sourceURL.lastPathComponent,
                              reason: trim(result.combinedOutput),
                              recovery: isLink ? .rebuild : .editAndRetry)
        }
        timeline.record(.compile, since: start, success: true)

        return Artifact(generation: generation, sourceURL: sourceURL, imageURL: imageURL)
    }

    private func trim(_ output: String) -> String {
        let lines = output.split(separator: "\n").filter { !$0.hasPrefix("clang: warning") }
        return lines.prefix(12).joined(separator: "\n")
    }
}

enum Subprocess {
    struct Result {
        let exitCode: Int32
        let combinedOutput: String
    }

    struct SeparatedResult {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// For callers that must not have the two streams interleaved, such as
    /// anything parsing structured output.
    static func runSeparated(_ executable: String, arguments: [String]) throws -> SeparatedResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a full pipe buffer would otherwise block the
        // child forever while the parent waits for it to exit.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SeparatedResult(exitCode: process.terminationStatus,
                               standardOutput: String(data: outData, encoding: .utf8) ?? "",
                               standardError: String(data: errData, encoding: .utf8) ?? "")
    }

    @discardableResult
    static func run(_ executable: String, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(exitCode: process.terminationStatus,
                      combinedOutput: String(data: data, encoding: .utf8) ?? "")
    }
}
