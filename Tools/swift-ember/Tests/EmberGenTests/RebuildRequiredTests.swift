import Testing
@testable import EmberGen

/// DESIGN.md section 19.3, one test per listed edit, plus the neighbouring
/// cases that share a reason. All of these must fail closed.
///
/// The value here is not that any single case is subtle -- most are obvious --
/// but that the list is exhaustive against the document, so a future change to
/// the indexer cannot quietly narrow what it refuses.

private func mustRebuild(_ baseline: String, _ current: String,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    switch ChangeClassifier.classify(baseline: baseline, current: current) {
    case .rebuildRequired:
        return
    case .hotPatch(let plan):
        Issue.record("accepted as hot patchable: \(plan.replacements.map(\.displayName))",
                     sourceLocation: sourceLocation)
    case .noChange:
        Issue.record("saw no change at all", sourceLocation: sourceLocation)
    }
}

// MARK: - Layout

@Test func storedPropertyAdded() {
    mustRebuild("struct U { var name: String }",
                "struct U { var name: String\n var age: Int }")
}

@Test func storedPropertyRemoved() {
    mustRebuild("struct U { var name: String\n var age: Int }",
                "struct U { var name: String }")
}

@Test func storedPropertyTypeChanged() {
    mustRebuild("struct U { var age: Int }",
                "struct U { var age: Double }")
}

@Test func storedPropertyReordered() {
    // Layout follows declaration order, so this is not cosmetic.
    mustRebuild("struct U { var a: Int\n var b: String }",
                "struct U { var b: String\n var a: Int }")
}

@Test func classStoredPropertyAdded() {
    mustRebuild("class Node { var next: Int = 0 }",
                "class Node { var next: Int = 0\n var previous: Int = 0 }")
}

// MARK: - Enums

@Test func enumCaseAdded() {
    mustRebuild("enum Status { case active }",
                "enum Status { case active\n case archived }")
}

@Test func enumCaseRemoved() {
    mustRebuild("enum Status { case active\n case archived }",
                "enum Status { case active }")
}

@Test func enumCasePayloadChanged() {
    mustRebuild("enum Event { case tap(Int) }",
                "enum Event { case tap(String) }")
}

// MARK: - Signatures

@Test func parameterAdded() {
    mustRebuild(#"struct P { func f(a: Int) -> String { "x" } }"#,
                #"struct P { func f(a: Int, b: Int) -> String { "x" } }"#)
}

@Test func parameterTypeChanged() {
    mustRebuild(#"struct P { func f(a: Int) -> String { "x" } }"#,
                #"struct P { func f(a: Double) -> String { "x" } }"#)
}

@Test func returnTypeChanged() {
    mustRebuild(#"struct P { func f() -> String { "x" } }"#,
                "struct P { func f() -> Int { 1 } }")
}

@Test func effectsAdded() {
    mustRebuild(#"struct P { func f() -> String { "x" } }"#,
                #"struct P { func f() async throws -> String { "x" } }"#)
}

@Test func mutatingRemoved() {
    mustRebuild("struct P { var n = 0\n mutating func bump() { n += 1 } }",
                "struct P { var n = 0\n func bump() { } }")
}

// MARK: - Generics and inheritance

@Test func genericConstraintChanged() {
    mustRebuild(#"func f<T: Equatable>(_ x: T) -> String { "x" }"#,
                #"func f<T: Hashable>(_ x: T) -> String { "x" }"#)
}

@Test func genericWhereClauseChanged() {
    mustRebuild(#"func f<T>(_ x: T) -> String where T: Equatable { "x" }"#,
                #"func f<T>(_ x: T) -> String where T: Hashable { "x" }"#)
}

@Test func superclassChanged() {
    mustRebuild(#"class A {}\#nclass B {}\#nclass C: A { func f() -> String { "x" } }"#,
                #"class A {}\#nclass B {}\#nclass C: B { func f() -> String { "x" } }"#)
}

@Test func conformanceAdded() {
    mustRebuild(#"struct S { func f() -> String { "x" } }"#,
                #"struct S: Equatable { func f() -> String { "x" } }"#)
}

// MARK: - Module shape

// Adding an ordinary declaration is no longer here: a patch can carry one,
// because nothing in the running binary could already be calling it. What
// still fails closed is adding one the patch cannot carry, since the only
// place a patch can put a member is an extension.

@Test func addedOverrideRequiresRebuild() {
    mustRebuild(#"class B { func f() -> String { "x" } }\#nclass C: B { }"#,
                #"class B { func f() -> String { "x" } }\#nclass C: B { override func f() -> String { "y" } }"#)
}

@Test func addedObjCMemberRequiresRebuild() {
    mustRebuild(#"class B: NSObject { }"#,
                #"class B: NSObject { @objc func f() -> String { "y" } }"#)
}

@Test func declarationRemoved() {
    mustRebuild(#"struct S { func f() -> String { "x" }\#n func g() -> String { "y" } }"#,
                #"struct S { func f() -> String { "x" } }"#)
}

@Test func typeAdded() {
    mustRebuild(#"struct S { func f() -> String { "x" } }"#,
                #"struct S { func f() -> String { "x" } }\#nstruct T {}"#)
}

@Test func importAdded() {
    mustRebuild(#"struct S { func f() -> String { "x" } }"#,
                #"import Foundation\#nstruct S { func f() -> String { "x" } }"#)
}

// MARK: - The promise itself

@Test func aRefusedChangeNeverProducesAPatch() {
    // Structural: whatever the reason, a rebuildRequired verdict must not carry
    // declarations forward. Nothing downstream should have anything to compile.
    let baseline = "struct U { var name: String\n func f() -> String { name } }"
    let current = "struct U { var name: String\n var age: Int\n func f() -> String { name } }"
    switch ChangeClassifier.classify(baseline: baseline, current: current) {
    case .rebuildRequired(let reason):
        #expect(!reason.isEmpty, "a refusal has to say why")
    default:
        Issue.record("expected a refusal")
    }
}

// MARK: - Declarations the index does not model

// These reach neither the patchable nor the unsupported map, so they have to
// land in the residue. A review found them reaching none of the three, which
// made a layout change read as no change at all.

@Test func commaSeparatedStoredPropertyAdded() {
    mustRebuild("struct S { var a = 1, b = 2 }",
                "struct S { var a = 1, b = 2, c = 3 }")
}

@Test func commaSeparatedStoredPropertyTypeChanged() {
    mustRebuild("struct S { var a: Int = 1, b: Int = 2 }",
                "struct S { var a: Int = 1, b: Double = 2 }")
}

@Test func tuplePatternPropertyChanged() {
    mustRebuild("struct S { let (a, b) = (1, 2) }",
                "struct S { let (a, b) = (1, 3) }")
}
