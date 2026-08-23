import Testing
@testable import SpliceGen

private let baseline = """
import Foundation

struct Price {
    var value: Int

    func formatted() -> String { "\\(value)" }

    var doubled: Int { value * 2 }

    @inlinable func fast() -> Int { value }

    private func secret() -> Int { value }
}

@MainActor
final class Screen {
    func title() -> String { "old" }
}

func topLevel<T: Equatable>(_ x: T, with y: T) async throws -> Bool where T: Hashable {
    x == y
}
"""

private func bodyEdit(_ source: String, _ from: String, _ to: String) -> String {
    let edited = source.replacingOccurrences(of: from, with: to)
    #expect(edited != source, "test fixture did not apply: \(from)")
    return edited
}

@Test func identicalSourceIsNoChange() {
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: baseline) else {
        Issue.record("expected noChange")
        return
    }
}

@Test func methodBodyChangeIsHotPatchable() throws {
    let current = bodyEdit(baseline, #"func formatted() -> String { "\(value)" }"#,
                           #"func formatted() -> String { "$\(value)" }"#)
    guard case .hotPatch(let declarations) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(declarations.map(\.identity) == ["Price.formatted()"])

    let source = try ReplacementGenerator.generate(module: "Demo", generation: 7, declarations: declarations)
    #expect(source.contains("@testable import Demo"))
    #expect(source.contains("extension Price {"))
    #expect(source.contains("@_dynamicReplacement(for: formatted())"))
    #expect(source.contains("func splice_g7_Price_formatted__() -> String"))
}

@Test func computedPropertyBodyChangeIsHotPatchable() throws {
    let current = bodyEdit(baseline, "var doubled: Int { value * 2 }", "var doubled: Int { value * 3 }")
    guard case .hotPatch(let declarations) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    let source = try ReplacementGenerator.generate(module: "Demo", generation: 1, declarations: declarations)
    #expect(source.contains("@_dynamicReplacement(for: doubled)"))
    #expect(source.contains("value * 3"))
}

@Test func genericsEffectsAndWhereClauseSurvive() throws {
    let current = bodyEdit(baseline, "    x == y", "    x != y")
    guard case .hotPatch(let declarations) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    let source = try ReplacementGenerator.generate(module: "Demo", generation: 2, declarations: declarations)
    #expect(source.contains("@_dynamicReplacement(for: topLevel(_:with:))"))
    #expect(source.contains("<T: Equatable>"))
    #expect(source.contains("async throws -> Bool"))
    #expect(source.contains("where T: Hashable"))
    // A top-level function must not be wrapped in an extension.
    #expect(!source.contains("extension  {"))
}

@Test func globalActorAttributeIsCarriedByTheType() throws {
    let current = bodyEdit(baseline, #"func title() -> String { "old" }"#,
                           #"func title() -> String { "new" }"#)
    guard case .hotPatch(let declarations) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(declarations.map(\.identity) == ["Screen.title()"])
    let source = try ReplacementGenerator.generate(module: "Demo", generation: 3, declarations: declarations)
    #expect(source.contains("extension Screen {"))
}

@Test func signatureChangeRequiresRebuild() {
    let current = bodyEdit(baseline, "func formatted() -> String", "func formatted(prefix: String) -> String")
    guard case .rebuildRequired(let reason) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
    #expect(reason.contains("declarations changed"))
}

@Test func addedStoredPropertyRequiresRebuild() {
    let current = bodyEdit(baseline, "    var value: Int\n", "    var value: Int\n    var tax: Int\n")
    guard case .rebuildRequired = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
}

@Test func changedStoredPropertyTypeRequiresRebuild() {
    let current = bodyEdit(baseline, "var value: Int", "var value: Double")
    guard case .rebuildRequired = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
}

@Test func inlinableBodyChangeRequiresRebuild() {
    let current = bodyEdit(baseline, "@inlinable func fast() -> Int { value }",
                           "@inlinable func fast() -> Int { value + 1 }")
    guard case .rebuildRequired(let reason) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
    #expect(reason.contains("@inlinable"))
}

@Test func privateBodyChangeRequiresRebuild() {
    let current = bodyEdit(baseline, "private func secret() -> Int { value }",
                           "private func secret() -> Int { value * 2 }")
    guard case .rebuildRequired(let reason) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
    #expect(reason.contains("private"))
}

@Test func addedImportRequiresRebuild() {
    let current = "import UIKit\n" + baseline
    guard case .rebuildRequired = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired")
        return
    }
}

@Test func reindentingIsNotAnEdit() {
    let current = baseline.replacingOccurrences(of: "    func formatted", with: "        func formatted")
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("whitespace should not register as a change")
        return
    }
}
