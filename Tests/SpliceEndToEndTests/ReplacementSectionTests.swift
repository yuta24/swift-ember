import Testing
import Foundation
@testable import SpliceGen

/// Pins the layout the runtime's FR-13 check reads.
///
/// `RegisteredReplacements` counts what an image registered by walking its
/// `__TEXT,__swift5_replace` section, and that layout is measured rather than
/// documented. It lives in the runtime target, which is compiled into the
/// application and cannot be imported here -- so what is pinned is the fact the
/// parser depends on: the scope's second word is the number of replacements,
/// and it equals the number the generator emitted.
///
/// A toolchain that changes this should fail here, loudly, rather than in
/// somebody's session as a reload that could not be confirmed.
private func replacementSection(of dylib: URL) throws -> [UInt32] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["otool", "-s", "__TEXT", "__swift5_replace", dylib.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    // "<address>\t<word> <word> <word> <word>"
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").dropFirst(2).flatMap { line -> [UInt32] in
        line.split(whereSeparator: \.isWhitespace).dropFirst()
            .compactMap { UInt32($0, radix: 16) }
    }
}

@Test(arguments: [1, 3]) func aPatchDeclaresTheReplacementsItEmitted(_ count: Int) throws {
    let members = (0..<count).map { "    func m\($0)() -> Int { \($0) }" }.joined(separator: "\n")
    let baseline = "struct S {\n\(members)\n}"
    let current = baseline.replacingOccurrences(of: "-> Int { ", with: "-> Int { 100 + ")

    guard case .hotPatch(let plan) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(plan.replacements.count == count)

    let outcome = try Loop.compileOnly(baseline: baseline, plan: plan)
    defer { try? FileManager.default.removeItem(at: outcome.work) }

    let words = try replacementSection(of: outcome.image)
    // section: flags, numScopes, then per scope a relative pointer and flags.
    #expect(words.count >= 4, "no replacement section: \(words)")
    #expect(words[1] == 1, "expected one scope, got \(words[1])")

    // The scope sits at a negative offset from the pointer field; the count is
    // its second word. Read it out of the file rather than re-deriving the
    // arithmetic here: what matters is that the emitted patch says `count`.
    let scope = try scopeWords(of: outcome.image, pointerWord: words[2])
    #expect(scope == UInt32(count), "the image registered \(scope), the patch emitted \(count)")
}

/// The scope's `numReplacements`, read through `otool -s __TEXT __const`-style
/// addressing: the relative pointer is stored at section start + 8.
private func scopeWords(of dylib: URL, pointerWord: UInt32) throws -> UInt32 {
    let data = try Data(contentsOf: dylib)
    let sectionAddress = try sectionStart(of: dylib)
    let pointerField = sectionAddress + 8
    let relative = Int32(bitPattern: pointerWord)
    let scope = pointerField + Int(relative)
    let offset = scope + 4
    guard offset + 4 <= data.count else { return .max }
    return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self)
    }
}

private func sectionStart(of dylib: URL) throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["otool", "-s", "__TEXT", "__swift5_replace", dylib.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard let line = text.split(separator: "\n").dropFirst(2).first,
          let address = line.split(whereSeparator: \.isWhitespace).first,
          let value = Int(address, radix: 16)
    else { throw Loop.Failure.build("no replacement section", text) }
    return value
}
