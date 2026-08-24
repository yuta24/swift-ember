import Foundation
import SpliceCore
import SpliceDaemon
import SpliceGen

// Measures how the patch pipeline scales with the size of the application it
// is patching. PRD.md M5 asks for a profile before any of the optimisation
// work in DESIGN.md 14 and 15 begins, and the examples are two files each,
// which says nothing about a real project.
//
// It drives the real ChangeClassifier, ReplacementGenerator, and PatchCompiler
// rather than reimplementing their invocations, so the numbers cannot drift
// from what the daemon does. The synthetic application is built for the macOS
// host: the stages under study are compile and link, and neither depends on
// which Apple platform the target names.

struct Size {
    let files: Int
    let declarationsPerFile: Int
    var total: Int { files * declarationsPerFile }
}

let sizes = [
    Size(files: 1, declarationsPerFile: 4),
    Size(files: 10, declarationsPerFile: 20),
    Size(files: 50, declarationsPerFile: 20),
    Size(files: 200, declarationsPerFile: 20),
    Size(files: 500, declarationsPerFile: 20),
]

let repetitions = 5
let module = "Bench"

/// One file of plausible-looking work: a type with stored properties, methods
/// that call each other, and a few generics, so the module interface a patch
/// has to load is not trivially small.
func source(file index: Int, declarations: Int) -> String {
    var lines = ["import Foundation", "", "struct Model\(index) {"]
    lines += (0..<3).map { "    var field\($0): Int = \($0)" }
    for declaration in 0..<declarations {
        lines.append("""
                func compute\(declaration)(_ input: Int) -> String {
                    let scaled = input * \(declaration + 1) + field\(declaration % 3)
                    return "m\(index).\(declaration):\\(scaled)"
                }
            """)
    }
    lines.append("""
            func describe<T: CustomStringConvertible>(_ value: T) -> String {
                "m\(index):\\(value)"
            }
        """)
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
}

/// The file the benchmark edits. Always the same shape, so the work the
/// pipeline does is constant and only the surrounding module grows.
func subjectSource(body: String) -> String {
    """
    import Foundation

    struct Subject {
        var seed: Int = 7

        func headline() -> String {
            \(body)
        }
    }
    """
}

func shell(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        FileHandle.standardError.write(data)
    }
    return process.terminationStatus
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func xcrunOutput(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

let sdkPath = try xcrunOutput(["--sdk", "macosx", "--show-sdk-path"])
// PatchCompiler execs this path directly, so it has to be the compiler itself.
let swiftcPath = try xcrunOutput(["--find", "swiftc"])

print("size         build      classify   generate   compile    link       total")
print(String(repeating: "-", count: 72))

for size in sizes {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("splice-bench-\(size.files)")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var sources: [String] = []
    for index in 0..<size.files {
        let url = root.appendingPathComponent("Model\(index).swift")
        try source(file: index, declarations: size.declarationsPerFile)
            .write(to: url, atomically: true, encoding: .utf8)
        sources.append(url.path)
    }
    let subjectURL = root.appendingPathComponent("Subject.swift")
    let baseline = subjectSource(body: #""headline:\(seed)""#)
    try baseline.write(to: subjectURL, atomically: true, encoding: .utf8)
    sources.append(subjectURL.path)

    let binary = root.appendingPathComponent("app")
    let buildStart = DispatchTime.now().uptimeNanoseconds
    let status = try shell(["swiftc", "-parse-as-library", "-Onone",
                            "-enable-testing",
                            "-Xfrontend", "-enable-implicit-dynamic",
                            "-module-name", module,
                            "-emit-module", "-emit-module-path",
                            root.appendingPathComponent("\(module).swiftmodule").path,
                            "-emit-library", "-o", binary.path] + sources)
    guard status == 0 else { print("build failed at \(size.files) files"); continue }
    let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000

    let context = BuildContext(
        moduleName: module,
        swiftCompilerPath: swiftcPath,
        swiftCompilerVersion: "bench",
        targetTriple: "arm64-apple-macosx26.0",
        sdkPath: sdkPath,
        sdkName: "macosx",
        appBinaryPath: binary.path,
        moduleSearchPaths: [root.path],
        extraCompilerFlags: [],
        sourceRoots: [root.path],
        bundleIdentifier: "dev.swift-splice.bench")

    let compiler = PatchCompiler(context: context, workDirectory: root.appendingPathComponent("patches"))

    var samples: [Stage: [Double]] = [:]
    var totals: [Double] = []

    for repetition in 0..<repetitions {
        let current = subjectSource(body: #""headline:\(seed) rev\#(repetition)""#)
        let timeline = StageTimeline(generation: UInt64(repetition + 1))

        let (index, classification) = timeline.measure(.classify) { () -> (FileIndex, ChangeClassification) in
            let after = DeclarationIndexer.index(source: current)
            return (after, ChangeClassifier.classify(
                before: DeclarationIndexer.index(source: baseline), after: after))
        }
        guard case .hotPatch(let declarations) = classification else {
            print("\(size.files) files: classifier refused the edit"); break
        }
        let generated = try timeline.measure(.generate) {
            try ReplacementGenerator.generate(module: module, generation: UInt64(repetition + 1),
                                              declarations: declarations, imports: index.imports)
        }
        _ = try compiler.compile(source: generated, generation: UInt64(repetition + 1), timeline: timeline)

        for event in timeline.all { samples[event.stage, default: []].append(event.durationMs) }
        totals.append(timeline.totalMs)
    }

    guard !totals.isEmpty else { continue }
    func column(_ stage: Stage) -> String {
        String(format: "%-10.0f", median(samples[stage] ?? [0]))
    }
    let label = "\(size.total) decls".padding(toLength: 13, withPad: " ", startingAt: 0)
    print(label
          + String(format: "%-10.0f", buildMs)
          + column(.classify) + column(.generate) + column(.compile) + column(.link)
          + String(format: "%.0f", median(totals)))
}

print("")
print("build is the whole application, once, for reference. Every other column")
print("is the median of \(repetitions) patches, in milliseconds.")
