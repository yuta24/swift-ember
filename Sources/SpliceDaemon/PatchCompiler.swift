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

    /// Two invocations, not one.
    ///
    /// DESIGN.md section 9.2 asks for compile and link timing kept separate,
    /// and section 14 cannot be decided without it: whether to pursue JITLink
    /// or a persistent compiler depends entirely on which of the two dominates.
    /// A single `-emit-library` reports one number for both and guesses at
    /// stage attribution by grepping the output.
    public func compile(source: String, generation: UInt64, timeline: StageTimeline) throws -> Artifact {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let name = String(format: "Patch_%03llu", generation)
        let sourceURL = workDirectory.appendingPathComponent("\(name).swift")
        let objectURL = workDirectory.appendingPathComponent("\(name).o")
        let imageURL = workDirectory.appendingPathComponent("\(name).dylib")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        try run(frontendArguments(source: sourceURL, object: objectURL, name: name),
                stage: .compile, subject: sourceURL.lastPathComponent,
                recovery: .editAndRetry, timeline: timeline)

        try run(linkArguments(object: objectURL, image: imageURL, name: name),
                stage: .link, subject: sourceURL.lastPathComponent,
                recovery: .rebuild, timeline: timeline)

        return Artifact(generation: generation, sourceURL: sourceURL, imageURL: imageURL)
    }

    private func run(_ arguments: [String], stage: Stage, subject: String,
                     recovery: SpliceError.Recovery, timeline: StageTimeline) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try Subprocess.run(context.swiftCompilerPath, arguments: arguments)
        guard result.exitCode == 0 else {
            timeline.record(stage, since: start, success: false)
            if let explanation = Self.explain(result.combinedOutput) {
                throw SpliceError(stage: stage, subject: subject,
                                  reason: explanation, recovery: .rebuild)
            }
            throw SpliceError(stage: stage, subject: subject,
                              reason: trim(result.combinedOutput), recovery: recovery)
        }
        timeline.record(stage, since: start, success: true)
    }

    private var common: [String] {
        var arguments = [
            "-Onone",
            "-target", context.targetTriple,
            "-sdk", context.sdkPath,
        ]
        for path in context.moduleSearchPaths { arguments += ["-I", path] }
        for path in context.frameworkSearchPaths { arguments += ["-F", path] }
        return arguments
    }

    private func frontendArguments(source: URL, object: URL, name: String) -> [String] {
        common + ["-c", "-o", object.path, "-module-name", name]
            + context.extraCompilerFlags + [source.path]
    }

    private func linkArguments(object: URL, image: URL, name: String) -> [String] {
        var arguments = common + [
            "-Xclang-linker", "-isysroot", "-Xclang-linker", context.sdkPath,
            "-emit-library", "-o", image.path, "-module-name", name, object.path,
        ]
        // Linking against the running binary resolves the replacement keys now
        // rather than at dlopen, so an ineligible declaration fails here with
        // "Undefined symbols" instead of inside the app.
        let target = context.linkTarget
        if target.hasSuffix(".dylib") {
            // An Xcode 16 debug dylib: a plain linker input, since
            // -bundle_loader only accepts an executable.
            arguments += ["-Xlinker", target]
        } else {
            arguments += ["-Xlinker", "-bundle",
                          "-Xlinker", "-bundle_loader", "-Xlinker", target]
        }
        return arguments
    }

    /// One compiler diagnostic is really a build setting, and says so nowhere.
    ///
    /// A patch reaches `private` declarations through `@_private(sourceFile:)`,
    /// which the module has to have been built for. Left untranslated, a
    /// project missing the setting is shown an error about generated source it
    /// never wrote, at a line it cannot open.
    static func explain(_ output: String) -> String? {
        guard output.contains("was not compiled for private import") else { return nil }
        return [
            "this module was not built for private imports, so the patch cannot reach its `private` declarations.",
            "",
            "Add the setting to the Debug configuration:",
            "",
            "    OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -enable-private-imports",
            "",
            "and to any local package's manifest, which Xcode does not pass OTHER_SWIFT_FLAGS into:",
            "",
            "    .unsafeFlags([\"-Xfrontend\", \"-enable-private-imports\"],",
            "                 .when(configuration: .debug))",
            "",
            "Then rebuild: the daemon reads the built binary, so the setting has no",
            "effect until the build it points at has been redone.",
        ].joined(separator: "\n")
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
