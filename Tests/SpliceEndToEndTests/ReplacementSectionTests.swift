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

    // Checked, because an empty result is load-bearing: a caller asserts that
    // an image has no replacement section, and a failed `otool` -- wrong path,
    // missing tool -- produces exactly the same empty array. `otool` prints
    // the file name even when the section is absent, so no output at all means
    // the call, not the section, is what was missing.
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, !text.isEmpty else {
        throw OtoolFailure(command: "otool -s __TEXT __swift5_replace",
                           status: process.terminationStatus, output: text)
    }

    // "<address>\t<word> <word> <word> <word>"
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

/// Pins how an `@objc` member's replacement actually arrives.
///
/// Not through the section above: measured, a patch replacing an `@objc`
/// method has no `__swift5_replace` section at all and carries an
/// Objective-C category, which the Objective-C runtime installs over the
/// class's own method at image load. The fixtures `objc-method`,
/// `override-objc-dispatch`, and `uikit-view-did-load` measure that the
/// replacement takes effect; what is pinned here is the shape the runtime's
/// counter depends on.
///
/// Two facts, and the second is the one that cost a debugging session: the
/// category carries *two* method entries for one replaced declaration -- the
/// original selector and the replacement's own -- and both name the same
/// implementation. Counting entries said two replacements for one edited
/// declaration and left every UIKit lifecycle reload reported as unverified.
@Test func anObjcReplacementArrivesAsOneCategoryImplementation() throws {
    let baseline = """
        import Foundation
        class C: NSObject {
            @objc func label() -> String { "old" }
        }
        """
    let current = baseline.replacingOccurrences(of: "\"old\"", with: "\"new\"")

    guard case .hotPatch(let plan) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(plan.replacements.count == 1)

    // `@objc` needs Foundation in the patch as well as in the source, which is
    // what the daemon's import forwarding is for.
    let outcome = try Loop.compileOnly(baseline: baseline, plan: plan, imports: ["import Foundation"])
    defer { try? FileManager.default.removeItem(at: outcome.work) }

    #expect(try replacementSection(of: outcome.image).isEmpty,
            "an @objc replacement is not supposed to emit a Swift replacement record")

    let category = try objcCategory(of: outcome.image)
    #expect(category.methodCount == 2,
            "expected the replaced selector and the replacement's own, got \(category.methodCount)")
    #expect(category.implementations == 1,
            "expected both entries to name one implementation, got \(category.implementations)")
}

/// What `otool -o` says about the image's one category.
private func objcCategory(of dylib: URL) throws -> (methodCount: Int, implementations: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["otool", "-o", dylib.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0, !text.isEmpty else {
        throw OtoolFailure(command: "otool -o", status: process.terminationStatus, output: text)
    }

    // Bounded to the catlist section. `otool -o` dumps several sections in
    // sequence, and an unbounded read summed every "count" line in all of
    // them: a category's own `instanceProperties` block has one, and so does
    // `__objc_classlist`'s `baseMethods`. On a patch replacing a get/set
    // property that turned a true 4 into 5.
    let opening = text.range(of: "Contents of (__DATA_CONST,__objc_catlist) section")
        ?? text.range(of: "Contents of (__DATA,__objc_catlist) section")
    guard let opening else { return (0, 0) }
    let rest = text[opening.upperBound...]
    let body = rest.range(of: "\nContents of (").map { rest[..<$0.lowerBound] } ?? rest

    // "count" appears under each of instanceMethods, classMethods, protocols
    // and instanceProperties, so which list is open decides whether it counts.
    // The resolved address in parentheses is the comparable half of an "imp"
    // line: the raw field is relative to its own position, so two entries
    // naming one function hold different numbers.
    var methodCount = 0
    var implementations: Set<String> = []
    var insideMethodList = false
    for line in body.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let first = fields.first else { continue }
        switch first {
        case "instanceMethods", "classMethods":
            insideMethodList = true
        case "protocols", "instanceProperties", "_classProperties", "name", "cls":
            insideMethodList = false
        case "count" where insideMethodList:
            methodCount += fields.dropFirst().first.flatMap { Int($0) } ?? 0
        case "imp":
            if let resolved = fields.last, resolved.hasPrefix("("), resolved.hasSuffix(")") {
                implementations.insert(String(resolved))
            }
        default:
            break
        }
    }
    return (methodCount, implementations.count)
}

private struct OtoolFailure: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: String
    var description: String {
        "\(command) exited \(status)\(output.isEmpty ? " with no output" : ": \(output)")"
    }
}

/// A computed property is one declaration and two replacement records.
///
/// The number FR-13 compares against is not `plan.replacements.count`, and
/// this is why: the image counts accessors. Counting declarations reported
/// every `{ get set }` edit as a reload that could not be confirmed, on a
/// patch that was entirely correct.
@Test func aGetSetPropertyEmitsOneRecordPerAccessor() throws {
    let baseline = """
        class C {
            var storage = 0
            var value: Int {
                get { storage }
                set { storage = newValue }
            }
        }
        """
    let current = baseline.replacingOccurrences(of: "{ storage }", with: "{ storage + 1 }")

    guard case .hotPatch(let plan) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(plan.replacements.count == 1, "one declaration changed")
    #expect(plan.replacements.first?.replacementCount == 2, "a getter and a setter")

    let outcome = try Loop.compileOnly(baseline: baseline, plan: plan)
    defer { try? FileManager.default.removeItem(at: outcome.work) }

    let words = try replacementSection(of: outcome.image)
    #expect(words.count >= 4, "no replacement section: \(words)")
    #expect(words[1] == 1, "expected one scope, got \(words[1])")
    let scope = try scopeWords(of: outcome.image, pointerWord: words[2])
    #expect(scope == 2, "the image registered \(scope) for one get/set property")
}

