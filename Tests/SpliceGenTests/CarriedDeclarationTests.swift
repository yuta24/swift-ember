import Testing
@testable import SpliceGen

/// What the classifier does with the edits it used to refuse: an `override`
/// body, a declaration that did not exist in the build, and a `private` one.
///
/// The toolchain half of each is pinned in `fixtures/Cases`. These pin the
/// decision and the source that comes out of it; `SpliceEndToEndTests` pins
/// that the source compiles, loads, and takes effect.

private func plan(_ baseline: String, _ current: String,
                  sourceLocation: SourceLocation = #_sourceLocation) -> PatchPlan? {
    switch ChangeClassifier.classify(baseline: baseline, current: current) {
    case .hotPatch(let plan):
        return plan
    case .noChange:
        Issue.record("saw no change at all", sourceLocation: sourceLocation)
        return nil
    case .rebuildRequired(let reason):
        Issue.record("refused: \(reason)", sourceLocation: sourceLocation)
        return nil
    }
}

private func refusal(_ baseline: String, _ current: String,
                     sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    switch ChangeClassifier.classify(baseline: baseline, current: current) {
    case .rebuildRequired(let reason):
        return reason
    case .noChange:
        Issue.record("saw no change at all", sourceLocation: sourceLocation)
        return nil
    case .hotPatch(let plan):
        Issue.record("accepted: \(plan.replacements.map(\.displayName))", sourceLocation: sourceLocation)
        return nil
    }
}

// MARK: - Overrides

private let subclass = """
class Screen {
    func title() -> String { "base" }
}

final class Detail: Screen {
    override func title() -> String { "old" }
    override var subtitle: String { "old-sub" }
}
"""

@Test func anOverrideBodyChangeIsPatchable() throws {
    let current = subclass.replacingOccurrences(of: #"{ "old" }"#, with: #"{ "new" }"#)
    guard let plan = plan(subclass, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Detail.title()"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("extension Detail {"))
    #expect(source.contains("@_dynamicReplacement(for: title())"))
    // The replacement is bound to the original's key rather than overriding
    // anything, and an extension cannot declare an override. Leaving the
    // modifier on is the one way to turn a working patch into a compile error.
    #expect(!source.contains("override"))
}

@Test func anOverriddenComputedPropertyIsPatchable() throws {
    let current = subclass.replacingOccurrences(of: #"{ "old-sub" }"#, with: #"{ "new-sub" }"#)
    guard let plan = plan(subclass, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Detail.subtitle"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("@_dynamicReplacement(for: subtitle)"))
    #expect(!source.contains("override"))
}

@Test func anOverrideThatCallsSuperKeepsTheCall() throws {
    let baseline = """
    class Screen { func setUp() -> String { "base" } }
    final class Detail: Screen {
        override func setUp() -> String { super.setUp() + "-old" }
    }
    """
    let current = baseline.replacingOccurrences(of: #""-old""#, with: #""-new""#)
    guard let plan = plan(baseline, current) else { return }
    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("super.setUp()"))
}

// MARK: - Private declarations
//
// Under `-enable-private-imports` these are ordinary replacements. Everything
// below was a refusal, or a carried copy with a guard around it, until the
// patch could simply name them.

private let withPrivateHelper = """
private func discount(_ cents: Int) -> Int { cents }

struct Order {
    var cents = 1000
    func total() -> String { "\\(discount(cents))" }
}
"""

@Test func aPrivateFunctionIsReplacedLikeAnyOther() throws {
    let current = withPrivateHelper.replacingOccurrences(
        of: "private func discount(_ cents: Int) -> Int { cents }",
        with: "private func discount(_ cents: Int) -> Int { cents - 100 }")
    guard let plan = plan(withPrivateHelper, current) else { return }

    // Only the declaration that changed. Its caller is untouched -- and still
    // sees the new implementation, because the replacement is bound at the key
    // the caller already goes through. A carried copy needed every caller
    // replaced along with it, and three guards to be sure that was possible.
    #expect(plan.replacements.map(\.displayName) == ["discount(_:) (Int)"])
    #expect(plan.carried.isEmpty)

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan,
                                                   privateImportOf: "Order.swift")
    #expect(source.contains(#"@_private(sourceFile: "Order.swift") @testable import M"#))
    #expect(source.contains("@_dynamicReplacement(for: discount(_:))"))
}

@Test func theImportIsOnlyPrivateWhenTheFileHasPrivateCode() throws {
    let plain = """
    struct Order {
        var cents = 1000
        func total() -> String { "\\(cents)" }
    }
    """
    #expect(DeclarationIndexer.index(source: plain).declaresFileLocal == false)
    #expect(DeclarationIndexer.index(source: withPrivateHelper).declaresFileLocal == true)

    let current = plain.replacingOccurrences(of: #"{ "\#\(cents)" }"#, with: #"{ "x\#\(cents)" }"#)
    guard let plan = plan(plain, current) else { return }
    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("@testable import M"))
    #expect(!source.contains("@_private"))
}

/// A default argument compiles into a generator function of its own. A carried
/// copy was invisible to it and the edit changed nothing while reporting
/// success; a replacement is bound at the key, so the generator finds it.
@Test func aPrivateHelperInADefaultArgumentIsPatchable() {
    let baseline = """
    private func base() -> Int { 10 }
    struct Cart {
        func total(_ n: Int = base()) -> Int { n }
    }
    """
    let current = baseline.replacingOccurrences(of: "-> Int { 10 }", with: "-> Int { 20 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.simpleNameForTest) == ["base"])
}

/// A body that reads private storage is the shape that decides reach in real
/// code, and it was the largest single cause of refusals.
@Test func aBodyReadingAPrivateStoredPropertyIsPatchable() {
    let baseline = """
    struct Cart {
        private var cents = 100
        func total() -> Int { cents }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ cents }", with: "{ cents + 1 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Cart.total()"])
}

@Test func aMemberOfAPrivateTypeIsPatchable() throws {
    let baseline = """
    private struct Helper {
        func compute() -> Int { 1 }
    }
    struct Cart { func total() -> Int { Helper().compute() } }
    """
    let current = baseline.replacingOccurrences(of: "func compute() -> Int { 1 }",
                                                with: "func compute() -> Int { 2 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Helper.compute()"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan,
                                                   privateImportOf: "Helper.swift")
    #expect(source.contains("extension Helper {"))
}

@Test func aMemberOfAPrivateExtensionIsPatchable() {
    let baseline = """
    struct Cart { var cents = 1 }
    private extension Cart {
        func fee() -> Int { 1 }
    }
    """
    let current = baseline.replacingOccurrences(of: "func fee() -> Int { 1 }",
                                                with: "func fee() -> Int { 5 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Cart.fee()"])
}

/// A fileprivate member overridden in the same file. Carrying a copy put it in
/// an extension, where it is statically dispatched, and the subclass's version
/// silently stopped running. Replacement binds at the key the vtable already
/// points at.
@Test func anOverriddenFileLocalMemberIsPatchable() {
    let baseline = """
    class Base {
        fileprivate func tick() -> String { "base" }
        func run() -> String { "run " + tick() }
    }
    class Sub: Base {
        override fileprivate func tick() -> String { "sub" }
    }
    """
    let current = baseline.replacingOccurrences(of: #""sub""#, with: #""SUB""#)
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Sub.tick()"])
}

@Test func aWitnessOfAPrivateProtocolIsPatchable() {
    let baseline = """
    private protocol Rule { func check() -> Bool }

    struct Impl: Rule {
        private func check() -> Bool { true }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ true }", with: "{ false }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Impl.check()"])
}

/// `private(set)` restricts the setter and leaves the declaration as visible as
/// it was written. Reading the keyword without its detail once filed it as
/// file-local, and a `private(set)` property nothing else named classified as
/// `noChange` -- a real edit, silently dropped.
@Test func privateSetIsNotFileLocal() throws {
    let baseline = """
    class Store {
        var storage = 0
        private(set) var total: Int {
            get { storage }
            set { storage = newValue }
        }
    }
    """
    #expect(DeclarationIndexer.index(source: baseline).declaresFileLocal == false)
    let current = baseline.replacingOccurrences(of: "get { storage }", with: "get { storage * 2 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Store.total"])
}

@Test func aRemovedDeclarationIsStillARebuild() {
    let current = withPrivateHelper
        .replacingOccurrences(of: "private func discount(_ cents: Int) -> Int { cents }\n", with: "")
        .replacingOccurrences(of: #"{ "\#\(discount(cents))" }"#, with: #"{ "\#\(cents)" }"#)
    guard let reason = refusal(withPrivateHelper, current) else { return }
    #expect(reason.contains("removed"))
}

// MARK: - Added declarations

@Test func anAddedHelperIsCarriedWhenSomethingCallsIt() throws {
    let baseline = """
    struct Order {
        var cents = 1000
        func total() -> String { "\\(cents)" }
    }
    """
    let current = """
    struct Order {
        var cents = 1000
        func total() -> String { dollars(cents) }
        func dollars(_ cents: Int) -> String { "$\\(cents / 100)" }
    }
    """
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
    #expect(plan.carried.map(\.simpleNameForTest) == ["dollars"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("func dollars(_ cents: Int) -> String"))
}

/// Adding a declaration nothing calls yet changes nothing a running process
/// could observe, and FR-13 says a patch that replaces nothing must not be
/// reported as a reload. The edit is not lost: the baseline only advances when
/// a patch lands, so the addition is still pending when the call arrives.
@Test func anAddedHelperNothingCallsIsPending() {
    let baseline = "struct Order {\n    func total() -> String { \"x\" }\n}"
    let current = "struct Order {\n    func total() -> String { \"x\" }\n    func dollars() -> String { \"y\" }\n}"
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected noChange")
        return
    }
}

@Test func addingAnOverrideIsARebuild() {
    let baseline = #"class B { func f() -> String { "x" } }\#nclass C: B { }"#
    let current = #"class B { func f() -> String { "x" } }\#nclass C: B { override func f() -> String { "y" } }"#
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("override"))
}

// MARK: - What the comparison key must and must not see

@Test func addingACommentIsNotAChange() {
    let baseline = """
    struct Order {
        func total() -> String { "x" }
        func other() -> String { "y" }
    }
    """
    let current = """
    /// The order.
    struct Order {
        func total() -> String { "x" }

        // MARK: - helpers
        /// Something else.
        func other() -> String { "y" }  // trailing
    }
    """
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected noChange; a comment is not an edit")
        return
    }
}

/// Whitespace was collapsed in the printed source, which collapsed it inside
/// string literals too, so this compared equal to its baseline and the save was
/// reported as no change at all.
@Test func whitespaceInsideAStringLiteralIsAChange() {
    let baseline = #"struct S { func label() -> String { "Total:  9" } }"#
    let current = #"struct S { func label() -> String { "Total: 9" } }"#
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["S.label()"])
}

@Test func aBlankLineInsideAMultiLineStringIsAChange() {
    let baseline = "struct S {\n    func text() -> String {\n        \"\"\"\n        a\n        b\n        \"\"\"\n    }\n}"
    let current = "struct S {\n    func text() -> String {\n        \"\"\"\n        a\n\n        b\n        \"\"\"\n    }\n}"
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["S.text()"])
}

/// A statement boundary is the one thing whitespace changes that Swift cares
/// about, and the parser has already resolved it, so the key reads the tree
/// rather than trying to re-derive it from newlines.
///
/// Here the newline before `-value()` makes it a statement of its own instead
/// of a subtraction. Not every newline does this: `return` followed by a
/// newline still takes the next line as its expression, in SwiftParser and in
/// `swiftc` alike, which is why the marker sits on statements rather than on
/// line breaks.
@Test func aStatementBoundaryIsAChange() {
    let baseline = """
    struct S {
        func run() -> Int {
            var total = value()
            total = total
            -value()
            return total
        }
        func value() -> Int { 3 }
    }
    """
    let current = baseline.replacingOccurrences(of: "total = total\n        -value()",
                                                with: "total = total - value()")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["S.run()"])
}

private extension PatchableDeclaration {
    /// The bare declared name, recovered from the display name for assertions.
    var simpleNameForTest: String {
        let head = displayName.split(separator: " ").first.map(String.init) ?? displayName
        let last = head.split(separator: ".").last.map(String.init) ?? head
        return last.split(separator: "(").first.map(String.init) ?? last
    }
}

// MARK: - Edits that look like body changes and are not

/// `#function` in a replaced body expands to the name the generator gave the
/// replacement --- measured as `label()` becoming `splice_g1_label____()` --- and
/// `#fileID` to the patch's own file. The wrong value lands in exactly the code
/// that exists to say where you are, with no diagnostic.
@Test func aBodyUsingASourceLocationLiteralIsRefused() {
    for literal in ["#function", "#fileID", "#file", "#line"] {
        let baseline = "struct S { func label() -> String { \"\\(\(literal))\" } }"
        let current = "struct S { func label() -> String { \"x\\(\(literal))\" } }"
        guard let reason = refusal(baseline, current) else { continue }
        #expect(reason.contains(literal), "reason was: \(reason)")
    }
}

/// An addition that overloads a name already in the binary changes what
/// *existing* code resolves to. Measured: adding `kind(_: Int)` beside
/// `kind(_: Any)` and editing one caller left the other caller on the old
/// resolution, so the process matched no version of the file.
@Test func anAddedOverloadIsRefused() {
    let baseline = """
    func kind(_ x: Any) -> String { "any" }
    func viaG() -> String { "g:" + kind(1) }
    func viaH() -> String { "h:" + kind(1) }
    """
    let current = """
    func kind(_ x: Any) -> String { "any" }
    func kind(_ x: Int) -> String { "int" }
    func viaG() -> String { "g!" + kind(1) }
    func viaH() -> String { "h:" + kind(1) }
    """
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("overloads"))
}

/// An addition that shares a name with a declaration on a *different* type is
/// not an overload of anything, and is carried as usual.
@Test func anAddedNameOnAnotherTypeIsNotAnOverload() {
    let baseline = """
    struct A { func kind() -> String { "a" } }
    struct B { func run() -> String { "b" } }
    """
    let current = """
    struct A { func kind() -> String { "a" } }
    struct B {
        func run() -> String { kind() }
        func kind() -> String { "bk" }
    }
    """
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.carried.map(\.displayName) == ["B.kind()"])
}

/// Which accessors a property declares is signature, not body. Gaining a setter
/// leaves `var v: Int` untouched, so it read as a body change: the patch loaded,
/// reported a reload, and the setter was dead, because the original key has no
/// setter to bind to.
@Test func gainingASetterIsASignatureChange() {
    let baseline = "final class Box { var store = 0\n var v: Int { store } }"
    let current = "final class Box { var store = 0\n var v: Int { get { store } set { store = newValue } } }"
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("signature"))
}

// MARK: - Across generations

/// A carried declaration lives in the patch dylib and nowhere else. Once a
/// patch lands the baseline advances, so without a memory of what was carried
/// it is neither carried again nor replaceable, and every later patch naming it
/// fails to compile -- permanently, since a rejection does not advance the
/// baseline either.
@Test func aCarriedDeclarationIsCarriedAgain() {
    let landed = """
    struct Order {
        var cents = 1000
        func total() -> String { dollars(cents) }
        func dollars(_ c: Int) -> String { "$\\(c / 100)" }
    }
    """
    var memory = SessionMemory()
    memory.carried = ["Order.dollars(_:)[Int]"]
    memory.replaced = ["Order.total()[]"]

    let edited = landed.replacingOccurrences(of: "{ dollars(cents) }", with: #"{ "=" + dollars(cents) }"#)
    guard case .hotPatch(let plan) = ChangeClassifier.classify(baseline: landed, current: edited,
                                                              memory: memory) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(plan.carried.map(\.displayName) == ["Order.dollars(_:) (Int)"])
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
}

/// Editing the carried declaration itself. Its callers were replaced by an
/// earlier patch and call *that* patch's copy, so they are re-emitted with it.
@Test func editingACarriedDeclarationReEmitsItsCallers() {
    let landed = """
    struct Order {
        var cents = 1000
        func total() -> String { dollars(cents) }
        func dollars(_ c: Int) -> String { "$\\(c / 100)" }
    }
    """
    var memory = SessionMemory()
    memory.carried = ["Order.dollars(_:)[Int]"]
    memory.replaced = ["Order.total()[]"]

    let edited = landed.replacingOccurrences(of: #""$\#\(c / 100)""#, with: #""USD \#\(c / 100)""#)
    guard case .hotPatch(let plan) = ChangeClassifier.classify(baseline: landed, current: edited,
                                                              memory: memory) else {
        Issue.record("expected hotPatch")
        return
    }
    #expect(plan.carried.map(\.displayName) == ["Order.dollars(_:) (Int)"])
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
}

@Test func aFileNameWithAQuoteIsEscaped() throws {
    let baseline = #"struct S { private func f() -> Int { 1 } }"#
    let current = #"struct S { private func f() -> Int { 2 } }"#
    guard let plan = plan(baseline, current) else { return }
    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan,
                                                   privateImportOf: #"we"ird\.swift"#)
    #expect(source.contains(#"@_private(sourceFile: "we\"ird\\.swift")"#),
            "generated: \(source.split(separator: "\n").prefix(4).joined(separator: " | "))")
}
