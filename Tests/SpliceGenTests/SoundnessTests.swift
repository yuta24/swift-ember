import Testing
@testable import SpliceGen

/// Cases where accepting the edit would be wrong. A review found every one of
/// these classified as hot patchable, or as no change at all, which is why they
/// are pinned here rather than left to the fixtures.
///
/// The two failure modes are not equally bad but both are unacceptable:
/// `hotPatch` on an unsafe edit corrupts a running process, and `noChange` on a
/// real edit leaves the developer watching stale code with no indication.

private func classify(_ baseline: String, _ current: String) -> ChangeClassification {
    ChangeClassifier.classify(baseline: baseline, current: current)
}

private func expectRebuild(_ baseline: String, _ current: String,
                           because fragment: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    switch classify(baseline, current) {
    case .rebuildRequired(let reason):
        #expect(reason.contains(fragment), "reason was: \(reason)", sourceLocation: sourceLocation)
    case .hotPatch(let declarations):
        Issue.record("accepted as hot patchable: \(declarations.map(\.identity))",
                     sourceLocation: sourceLocation)
    case .noChange:
        Issue.record("reported no change at all", sourceLocation: sourceLocation)
    }
}

// MARK: - Opaque result types

// The compiler accepts this, the loader accepts it, and the process then
// behaves as undefined. DESIGN.md 12.7. This classifier is the only defense.

@Test func opaquePropertyIsNeverHotPatchable() {
    expectRebuild(
        #"struct Renderer { var body: some CustomStringConvertible { "old" } }"#,
        #"struct Renderer { var body: some CustomStringConvertible { 42 } }"#,
        because: "opaque result type")
}

@Test func opaqueFunctionResultIsNeverHotPatchable() {
    expectRebuild(
        #"struct Renderer { func make() -> some CustomStringConvertible { "old" } }"#,
        #"struct Renderer { func make() -> some CustomStringConvertible { 42 } }"#,
        because: "opaque result type")
}

@Test func opaqueIsRejectedEvenWhenTheUnderlyingTypeIsUnchanged() {
    // Over-approximate on purpose: proving the underlying type is the same
    // needs type checking, and guessing wrong here is memory-unsafe.
    expectRebuild(
        #"struct Renderer { var body: some CustomStringConvertible { "old" } }"#,
        #"struct Renderer { var body: some CustomStringConvertible { "new" } }"#,
        because: "opaque result type")
}

// MARK: - Protocols

@Test func protocolRequirementChangeIsNotABodyEdit() {
    // ProtocolDeclSyntax conforms to both DeclGroupSyntax and NamedDeclSyntax,
    // so an ordering mistake in the walker had protocols walked as concrete
    // types and `{ get set }` mistaken for an implementation.
    expectRebuild(
        "protocol Store { var foo: Int { get set } }",
        "protocol Store { var foo: Int { get } }",
        because: "outside a replaceable declaration")
}

@Test func protocolExtensionDefaultIsStillHotPatchable() {
    let baseline = """
    protocol Store { func describe() -> String }
    extension Store { func describe() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: #""old""#, with: #""new""#)
    guard case .hotPatch(let declarations) = classify(baseline, current) else {
        Issue.record("a default implementation is an ordinary body")
        return
    }
    #expect(declarations.count == 1)
}

// MARK: - Identity collisions

@Test func overloadsSharingLabelsAreToldApart() {
    // Keying identity on argument labels alone made these two collide, and the
    // edit to whichever lost the dictionary write vanished entirely.
    let baseline = """
    struct Converter {
        func run(value: Int) -> String { "int" }
        func run(value: String) -> String { "str" }
    }
    """
    let current = baseline.replacingOccurrences(of: #""int""#, with: #""int-changed""#)
    guard case .hotPatch(let declarations) = classify(baseline, current) else {
        Issue.record("expected the Int overload to be recognised")
        return
    }
    #expect(declarations.count == 1)
    #expect(declarations[0].identity.contains("Int"))
}

@Test func trulyIndistinguishableDeclarationsAreRefused() {
    // Same type, same name, same parameter types, different constraint: the
    // index cannot tell them apart, so neither is patchable.
    let baseline = """
    extension Array { func helper() -> Int { 1 } }
    extension Array { func helper() -> Int { 2 } }
    """
    let current = baseline.replacingOccurrences(of: "{ 1 }", with: "{ 9 }")
    expectRebuild(baseline, current, because: "cannot tell them apart")
}

@Test func constrainedExtensionsKeepTheirWhereClause() {
    let baseline = """
    extension Array where Element == Int { func sum2() -> Int { 1 } }
    extension Array where Element == String { func sum2() -> Int { 2 } }
    """
    let current = baseline.replacingOccurrences(of: "{ 1 }", with: "{ 9 }")
    guard case .hotPatch(let declarations) = classify(baseline, current) else {
        Issue.record("expected the Int-constrained extension to be recognised")
        return
    }
    let source = try! ReplacementGenerator.generate(module: "M", generation: 1, declarations: declarations)
    // Generating into a bare `extension Array` would drop the constraint the
    // body relies on and the patch would not compile.
    #expect(source.contains("extension Array where Element == Int {"))
    #expect(!source.contains("extension Array {"))
}

// MARK: - Storage

@Test func propertyObserversAreStorage() {
    // willSet/didSet have an accessor block but real backing storage, so they
    // are not computed properties.
    expectRebuild(
        "class Box { var count: Int = 0 { didSet { print(oldValue) } } }",
        "class Box { var count: Int = 0 { didSet { print(count) } } }",
        because: "stored property")
}

@Test func propertyWrappersAreStorage() {
    expectRebuild(
        "class Box { @Published var count: Int = 0 }",
        "class Box { @Published var count: Int = 1 }",
        because: "stored property")
}

// MARK: - Ordering

@Test func reorderingEnumCasesIsAChange() {
    // Sorting the residue before hashing it made a pure reordering invisible.
    expectRebuild(
        "enum Status { case active\n case inactive }",
        "enum Status { case inactive\n case active }",
        because: "outside a replaceable declaration")
}

@Test func reorderingMethodsIsNotAChange() {
    // Order matters for the residue, but declarations are keyed by identity,
    // so moving a method must not force a rebuild.
    let baseline = """
    struct Pair {
        func a() -> Int { 1 }
        func b() -> Int { 2 }
    }
    """
    let current = """
    struct Pair {
        func b() -> Int { 2 }
        func a() -> Int { 1 }
    }
    """
    guard case .noChange = classify(baseline, current) else {
        Issue.record("moving a method is not an edit")
        return
    }
}

// MARK: - Constructs the index does not model

@Test func subscriptAndInitChangesForceRebuild() {
    expectRebuild(
        "struct Table { init() {}\n subscript(i: Int) -> Int { i } }",
        "struct Table { init() {}\n subscript(i: Int) -> Int { i * 2 } }",
        because: "outside a replaceable declaration")
}

@Test func operatorChangesForceRebuild() {
    expectRebuild(
        "struct V {}\nfunc + (a: V, b: V) -> Int { 1 }",
        "struct V {}\nfunc + (a: V, b: V) -> Int { 2 }",
        because: "operator")
}

@Test func nestedTypeMethodsAreAddressedByTheirFullPath() {
    let baseline = """
    enum Outer {
        struct Inner {
            func f() -> Int { 1 }
        }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ 1 }", with: "{ 2 }")
    guard case .hotPatch(let declarations) = classify(baseline, current) else {
        Issue.record("expected a nested method to be patchable")
        return
    }
    #expect(declarations[0].contextPath == "Outer.Inner")
    let source = try! ReplacementGenerator.generate(module: "M", generation: 1, declarations: declarations)
    #expect(source.contains("extension Outer.Inner {"))
}
