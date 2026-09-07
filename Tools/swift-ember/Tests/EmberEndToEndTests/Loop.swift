import Foundation
import Testing
import EmberGen

/// Runs a source edit through the real pipeline and into a real process.
///
/// `fixtures/` establishes what the Swift toolchain does with hand-written
/// patches; `EmberGenTests` establishes what the classifier decides. Neither
/// checks that a verdict of `.hotPatch` produces a patch that compiles, loads,
/// and returns the right answer. That gap is what let a review find a generator
/// bug -- constrained extensions losing their `where` clause -- that unit tests
/// on the verdict alone could never have caught.
///
/// Host-only and deliberately so: the toolchain behaviour these depend on is
/// already pinned on the Simulator by `fixtures/run.sh --platform simulator`,
/// and building for the host keeps a full pass in seconds rather than minutes.
enum Loop {
    struct Outcome {
        var before: [String]
        var after: [String]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EmberEndToEndTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-ember tool package
            .deletingLastPathComponent()   // Tools
            .deletingLastPathComponent()   // repo
    }

    private static var harness: URL {
        repoRoot.appendingPathComponent("fixtures/Harness/Harness.swift")
    }

    /// Builds `baseline`, edits it to `current`, and applies whatever the
    /// pipeline produces to the running-then-relaunched fixture.
    ///
    /// The process is started fresh for each generation rather than kept alive,
    /// because what is under test here is the generator, not state preservation
    /// -- `examples/CounterApp` covers that, in a real app.
    static func run(baseline: String, current: String,
                    sourceLocation: SourceLocation = #_sourceLocation) throws -> Outcome {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let module = "Fixture"
        let appSource = work.appendingPathComponent("App.swift")
        try baseline.write(to: appSource, atomically: true, encoding: .utf8)

        let binary = work.appendingPathComponent("app")
        try compileApplication(sources: [harness, appSource], module: module,
                               into: work, binary: binary)

        let before = try execute(binary, arguments: [])

        // Indexed and generated exactly as PatchCoordinator does it, imports
        // included. Calling the generator a shorter way here meant the suite
        // that exists to prove a patch actually compiles was not exercising
        // the path the daemon takes.
        let currentIndex = DeclarationIndexer.index(source: current)
        let classification = ChangeClassifier.classify(
            before: DeclarationIndexer.index(source: baseline), after: currentIndex)
        guard case .hotPatch(let plan) = classification else {
            throw Failure.notHotPatchable(classification)
        }

        let generated = try ReplacementGenerator.generate(
            module: module, generation: 1, plan: plan, imports: currentIndex.imports,
            privateImportOf: currentIndex.declaresFileLocal ? "App.swift" : nil)
        let patchSource = work.appendingPathComponent("Patch.swift")
        try generated.write(to: patchSource, atomically: true, encoding: .utf8)

        let image = work.appendingPathComponent("Patch.dylib")
        try compilePatch(source: patchSource, moduleSearchPath: work,
                         appBinary: binary, image: image, generatedSource: generated)

        let after = try execute(binary, arguments: [image.path])
        return Outcome(before: before, after: after)
    }

    /// Builds and loads one atomic image from several original source files.
    /// This is the production shape: private imports remain file-scoped, the
    /// compiler sees cross-file carried declarations, and dyld receives one
    /// image rather than a sequence that cannot be rolled back.
    static func runAtomic(baselines: [String], currents: [String]) throws -> Outcome {
        precondition(!baselines.isEmpty && baselines.count == currents.count)
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-e2e-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let module = "Fixture"
        let appSources = try baselines.enumerated().map { offset, source in
            let url = work.appendingPathComponent("Source\(offset + 1).swift")
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let binary = work.appendingPathComponent("app")
        try compileApplication(sources: [harness] + appSources, module: module,
                               into: work, binary: binary)
        let before = try execute(binary, arguments: [])

        var files: [PatchFilePlan] = []
        for (offset, pair) in zip(baselines, currents).enumerated() {
            let currentIndex = DeclarationIndexer.index(source: pair.1)
            let classification = ChangeClassifier.classifyForBatch(
                before: DeclarationIndexer.index(source: pair.0), after: currentIndex)
            switch classification {
            case .noChange:
                continue
            case .rebuildRequired:
                throw Failure.notHotPatchable(classification)
            case .hotPatch(let plan):
                files.append(PatchFilePlan(
                    plan: plan, imports: currentIndex.imports,
                    privateImportOf: currentIndex.declaresFileLocal
                        ? appSources[offset].lastPathComponent : nil))
            }
        }
        guard files.contains(where: { !$0.plan.replacements.isEmpty }) else {
            throw Failure.notHotPatchable(.noChange)
        }

        let generated = try ReplacementGenerator.generateFiles(
            module: module, generation: 1, files: files)
        let patchSources = try generated.enumerated().map { offset, source in
            let url = work.appendingPathComponent("Patch_\(offset + 1).swift")
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let image = work.appendingPathComponent("Patch.dylib")
        try compilePatch(sources: patchSources, moduleSearchPath: work,
                         appBinary: binary, image: image,
                         generatedSources: generated)
        let after = try execute(binary, arguments: [image.path])
        return Outcome(before: before, after: after)
    }

    /// Runs several complete multi-file source snapshots through one process.
    /// Each generation includes the changed files plus every contribution the
    /// earlier images left resident, matching the coordinator's module-wide
    /// carry behavior.
    static func runAtomicGenerations(_ versions: [[String]]) throws -> [String] {
        precondition(versions.count >= 2 && !versions[0].isEmpty)
        precondition(versions.allSatisfy { $0.count == versions[0].count })
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-e2e-atomic-generations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let module = "Fixture"
        let appSources = try versions[0].enumerated().map { offset, source in
            let url = work.appendingPathComponent("Source\(offset + 1).swift")
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let binary = work.appendingPathComponent("app")
        try compileApplication(sources: [harness] + appSources, module: module,
                               into: work, binary: binary)

        var baselines = versions[0]
        var memories = Array(repeating: SessionMemory(), count: baselines.count)
        var images: [String] = []

        for (generationOffset, currents) in versions.dropFirst().enumerated() {
            let generation = UInt64(generationOffset + 1)
            var changedPlans: [Int: (index: FileIndex, plan: PatchPlan)] = [:]
            for offset in currents.indices where currents[offset] != baselines[offset] {
                let index = DeclarationIndexer.index(source: currents[offset])
                let classification = ChangeClassifier.classifyForBatch(
                    before: DeclarationIndexer.index(source: baselines[offset]),
                    after: index, memory: memories[offset])
                guard case .hotPatch(let plan) = classification else {
                    throw Failure.notHotPatchable(classification)
                }
                changedPlans[offset] = (index, plan)
            }

            var files: [PatchFilePlan] = []
            for offset in currents.indices {
                let index: FileIndex
                let plan: PatchPlan
                if let changed = changedPlans[offset] {
                    index = changed.index
                    plan = changed.plan
                } else {
                    index = DeclarationIndexer.index(source: baselines[offset])
                    let carried = memories[offset].carried.compactMap { index.patchable[$0] }
                    let replacements = memories[offset].replaced
                        .subtracting(memories[offset].carried)
                        .compactMap { index.patchable[$0] }
                    guard !carried.isEmpty || !replacements.isEmpty else { continue }
                    plan = PatchPlan(replacements: replacements, carried: carried)
                }
                files.append(PatchFilePlan(
                    plan: plan, imports: index.imports,
                    privateImportOf: index.declaresFileLocal
                        ? appSources[offset].lastPathComponent : nil))
            }
            guard files.contains(where: { !$0.plan.replacements.isEmpty }) else {
                throw Failure.notHotPatchable(.noChange)
            }

            let generated = try ReplacementGenerator.generateFiles(
                module: module, generation: generation, files: files)
            let patchSources = try generated.enumerated().map { offset, source in
                let url = work.appendingPathComponent(
                    "Patch_\(generation)_\(offset + 1).swift")
                try source.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            let image = work.appendingPathComponent("Patch_\(generation).dylib")
            try compilePatch(sources: patchSources, moduleSearchPath: work,
                             appBinary: binary, image: image,
                             generatedSources: generated)
            images.append(image.path)

            for (offset, changed) in changedPlans {
                memories[offset].remember(changed.plan)
                baselines[offset] = currents[offset]
            }
        }

        return try execute(binary, arguments: images)
    }

    /// Several saves in a row against one process, the way a session actually
    /// goes: each patch is generated with the memory of what the ones before it
    /// put in, and all of them are loaded in order.
    ///
    /// One generation was all this harness could do, and that is why a patch
    /// naming a declaration an earlier patch had carried --- extract a helper,
    /// then keep tuning the caller, the most ordinary loop there is --- shipped
    /// broken. Everything single-generation passed.
    static func runGenerations(_ versions: [String],
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        precondition(versions.count >= 2, "a run needs a baseline and at least one edit")
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let module = "Fixture"
        let appSource = work.appendingPathComponent("App.swift")
        try versions[0].write(to: appSource, atomically: true, encoding: .utf8)

        let binary = work.appendingPathComponent("app")
        try compileApplication(sources: [harness, appSource], module: module,
                               into: work, binary: binary)

        var memory = SessionMemory()
        var baseline = versions[0]
        var images: [String] = []

        for (offset, current) in versions.dropFirst().enumerated() {
            let generation = UInt64(offset + 1)
            let currentIndex = DeclarationIndexer.index(source: current)
            let classification = ChangeClassifier.classify(
                before: DeclarationIndexer.index(source: baseline), after: currentIndex,
                memory: memory)
            guard case .hotPatch(let plan) = classification else {
                throw Failure.notHotPatchable(classification)
            }

            let generated = try ReplacementGenerator.generate(
                module: module, generation: generation, plan: plan, imports: currentIndex.imports,
                privateImportOf: currentIndex.declaresFileLocal ? "App.swift" : nil)
            let patchSource = work.appendingPathComponent("Patch\(generation).swift")
            try generated.write(to: patchSource, atomically: true, encoding: .utf8)

            let image = work.appendingPathComponent("Patch\(generation).dylib")
            try compilePatch(source: patchSource, moduleSearchPath: work,
                             appBinary: binary, image: image, generatedSource: generated)
            images.append(image.path)

            // The daemon advances both only when the patch lands.
            memory.remember(plan)
            baseline = current
        }

        return try execute(binary, arguments: images)
    }

    struct CompiledPatch {
        var work: URL
        var image: URL
    }

    /// Builds an application and one patch, and stops there.
    ///
    /// For checks about the *artifact* rather than about what it does when
    /// loaded --- the shape of its replacement section, say.
    static func compileOnly(baseline: String, plan: PatchPlan,
                            imports: [String] = []) throws -> CompiledPatch {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let module = "Fixture"
        let appSource = work.appendingPathComponent("App.swift")
        try (baseline + "\n" + "func probe() async throws -> [String] { [] }\n")
            .write(to: appSource, atomically: true, encoding: .utf8)

        let binary = work.appendingPathComponent("app")
        try compileApplication(sources: [harness, appSource], module: module,
                               into: work, binary: binary)

        let generated = try ReplacementGenerator.generate(module: module, generation: 1, plan: plan,
                                                          imports: imports)
        let patchSource = work.appendingPathComponent("Patch.swift")
        try generated.write(to: patchSource, atomically: true, encoding: .utf8)

        let image = work.appendingPathComponent("Patch.dylib")
        try compilePatch(source: patchSource, moduleSearchPath: work,
                         appBinary: binary, image: image, generatedSource: generated)
        return CompiledPatch(work: work, image: image)
    }

    enum Failure: Error, CustomStringConvertible {
        case notHotPatchable(ChangeClassification)
        case build(String, String)
        case crashed(Int32, String)

        var description: String {
            switch self {
            case .notHotPatchable(let classification):
                switch classification {
                case .noChange: "the classifier saw no change"
                case .rebuildRequired(let reason): "the classifier refused: \(reason)"
                case .hotPatch: "unreachable"
                }
            case .build(let what, let output): "\(what) failed:\n\(output)"
            case .crashed(let status, let output): "the fixture exited with \(status)\n\(output)"
            }
        }
    }

    // MARK: - Toolchain

    private static func compileApplication(sources: [URL], module: String,
                                           into directory: URL, binary: URL) throws {
        // The same four settings examples/CounterApp/build.sh uses.
        var arguments = ["swiftc", "-parse-as-library", "-Onone",
                         "-enable-testing",
                         "-Xfrontend", "-enable-implicit-dynamic",
                         "-Xfrontend", "-enable-private-imports",
                         "-module-name", module,
                         "-emit-module", "-emit-module-path",
                         directory.appendingPathComponent("\(module).swiftmodule").path,
                         "-emit-executable", "-o", binary.path]
        arguments += sources.map(\.path)
        let result = try shell(arguments)
        guard result.status == 0 else { throw Failure.build("the fixture build", result.output) }
    }

    private static func compilePatch(source: URL, moduleSearchPath: URL, appBinary: URL,
                                     image: URL, generatedSource: String) throws {
        let result = try shell(["swiftc", "-Onone",
                                "-emit-library", "-o", image.path,
                                "-module-name", "Patch",
                                "-I", moduleSearchPath.path,
                                source.path,
                                "-Xlinker", "-bundle",
                                "-Xlinker", "-bundle_loader", "-Xlinker", appBinary.path])
        guard result.status == 0 else {
            throw Failure.build("the patch build", result.output + "\n--- generated ---\n" + generatedSource)
        }
    }

    private static func compilePatch(sources: [URL], moduleSearchPath: URL, appBinary: URL,
                                     image: URL, generatedSources: [String]) throws {
        let object = image.deletingPathExtension().appendingPathExtension("o")
        var compile = ["swiftc", "-Onone", "-whole-module-optimization",
                       "-c", "-o", object.path,
                       "-module-name", "Patch", "-I", moduleSearchPath.path]
        compile += sources.map(\.path)
        let compiled = try shell(compile)
        let dump = generatedSources.enumerated().map {
            "--- generated \($0.offset + 1) ---\n\($0.element)"
        }.joined(separator: "\n")
        guard compiled.status == 0 else {
            throw Failure.build("the atomic patch compile", compiled.output + "\n" + dump)
        }

        let linked = try shell([
            "swiftc", "-Onone", "-emit-library", "-o", image.path,
            "-module-name", "Patch", object.path,
            "-Xlinker", "-bundle",
            "-Xlinker", "-bundle_loader", "-Xlinker", appBinary.path,
        ])
        guard linked.status == 0 else {
            throw Failure.build("the atomic patch link", linked.output + "\n" + dump)
        }
    }

    private static func execute(_ binary: URL, arguments: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure.crashed(process.terminationStatus, output)
        }
        return output.split(separator: "\n").map(String.init)
    }

    private static func shell(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Runs one edit and asserts what the process printed before and after.
///
/// Shared rather than private to one file: the declaration-kind cases and the
/// carried-declaration cases assert the same shape, and two copies would drift.
func expectReload(_ baseline: String, _ current: String,
                  before expectedBefore: [String], after expectedAfter: [String],
                  sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        let outcome = try Loop.run(baseline: baseline, current: current)
        #expect(outcome.before == expectedBefore.map { "g0: \($0)" }, sourceLocation: sourceLocation)
        #expect(outcome.after.suffix(expectedAfter.count) == expectedAfter.map { "g1: \($0)" }[...],
                "full output: \(outcome.after)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("\(error)", sourceLocation: sourceLocation)
    }
}

func probe(_ body: String) -> String {
    "func probe() async throws -> [String] { \(body) }"
}
