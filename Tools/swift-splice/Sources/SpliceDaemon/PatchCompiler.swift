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
    public func compile(source: String, generation: UInt64, flags: [String]? = nil,
                        timeline: StageTimeline) throws -> Artifact {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let name = String(format: "Patch_%03llu", generation)
        let sourceURL = workDirectory.appendingPathComponent("\(name).swift")
        let objectURL = workDirectory.appendingPathComponent("\(name).o")
        let imageURL = workDirectory.appendingPathComponent("\(name).dylib")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        try compile(frontendArguments(source: sourceURL, object: objectURL, name: name,
                                      flags: flags ?? context.extraCompilerFlags),
                    subject: sourceURL.lastPathComponent, timeline: timeline)

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

    /// A local Swift package can expose a Swift module whose transitive graph
    /// contains a Clang target. Xcode passes that target's generated module map
    /// to the package compile, but `-showBuildSettings` for the application
    /// does not report it. Resolve only the module the compiler asks for and
    /// retry; adding every map in DerivedData can introduce duplicate modules.
    private func compile(_ initialArguments: [String], subject: String,
                         timeline: StageTimeline) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        var arguments = initialArguments
        var recovered: Set<String> = []

        while true {
            let result = try Subprocess.run(context.swiftCompilerPath, arguments: arguments)
            if result.exitCode == 0 {
                timeline.record(.compile, since: start, success: true)
                return
            }

            if let module = Self.missingRequiredModule(in: result.combinedOutput),
               recovered.insert(module).inserted,
               let map = moduleMap(named: module) {
                arguments += ["-Xcc", "-fmodule-map-file=\(map.path)"]
                continue
            }

            timeline.record(.compile, since: start, success: false)
            if let explanation = Self.explain(result.combinedOutput) {
                throw SpliceError(stage: .compile, subject: subject,
                                  reason: explanation, recovery: .rebuild)
            }
            throw SpliceError(stage: .compile, subject: subject,
                              reason: trim(result.combinedOutput), recovery: .editAndRetry)
        }
    }

    static func missingRequiredModule(in output: String) -> String? {
        let prefix = "missing required module '"
        guard let start = output.range(of: prefix)?.upperBound,
              let end = output[start...].firstIndex(of: "'") else { return nil }
        return String(output[start..<end])
    }

    private func moduleMap(named module: String) -> URL? {
        let marker = "/Build/"
        guard let boundary = context.linkTarget.range(of: marker) else { return nil }
        let derivedData = URL(fileURLWithPath: String(context.linkTarget[..<boundary.lowerBound]))
        let roots = [
            derivedData.appendingPathComponent("SourcePackages/checkouts", isDirectory: true),
            derivedData.appendingPathComponent("Build/Intermediates.noindex/GeneratedModuleMaps-\(context.sdkName)",
                                               isDirectory: true),
            derivedData.appendingPathComponent("Build/Intermediates.noindex/GeneratedModuleMaps",
                                               isDirectory: true),
        ]

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension == "modulemap" {
                if url.deletingPathExtension().lastPathComponent == module { return url }
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      Self.moduleMap(source, declares: module) else { continue }
                return url
            }
        }
        return nil
    }

    static func moduleMap(_ source: String, declares module: String) -> Bool {
        source.split(separator: "\n").contains { line in
            let words = line.split { $0.isWhitespace || $0 == "{" || $0 == "[" }
            guard let marker = words.firstIndex(of: "module"), marker + 1 < words.count else {
                return false
            }
            return words[marker + 1] == Substring(module)
        }
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

    private func frontendArguments(source: URL, object: URL, name: String, flags: [String]) -> [String] {
        common + ["-c", "-o", object.path, "-module-name", name] + flags + [source.path]
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

/// Somewhere for two concurrent readers to put what they read.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func store(_ data: Data, isStandardOutput: Bool) {
        lock.withLock {
            if isStandardOutput { standardOutput = data } else { standardError = data }
        }
    }

    func text(isStandardOutput: Bool) -> String {
        lock.withLock {
            String(data: isStandardOutput ? standardOutput : standardError, encoding: .utf8) ?? ""
        }
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

        // Both pipes are drained at the same time.
        //
        // Reading one to EOF and then the other is the same deadlock as waiting
        // before reading, which the comment that used to sit here was about: the
        // child fills the pipe nobody is draining, blocks, and never closes the
        // one the parent is waiting on. Measured on the exact shape this call
        // has -- a child writing to stderr and little to stdout -- 64 KB came
        // back fine and 300 KB hung forever. The caller is
        // `xcodebuild -showBuildSettings` at daemon start, so the symptom was
        // `watch` never finishing starting, with nothing printed.
        let collected = Collected()
        let group = DispatchGroup()
        for (handle, isStandardOutput) in [(out.fileHandleForReading, true),
                                           (err.fileHandleForReading, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = handle.readDataToEndOfFile()
                collected.store(data, isStandardOutput: isStandardOutput)
                group.leave()
            }
        }
        group.wait()
        process.waitUntilExit()

        return SeparatedResult(exitCode: process.terminationStatus,
                               standardOutput: collected.text(isStandardOutput: true),
                               standardError: collected.text(isStandardOutput: false))
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
