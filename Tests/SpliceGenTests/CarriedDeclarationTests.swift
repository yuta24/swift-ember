import Testing
@testable import SpliceGen

/// What the classifier does with the three edits it used to refuse: an
/// `override` body, a declaration that did not exist in the build, and a
/// `private` one.
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

private let withPrivateHelper = """
private func discount(_ cents: Int) -> Int { cents }

struct Order {
    var cents = 1000
    func total() -> String { "\\(discount(cents))" }
}
"""

@Test func aPrivateChangeReplacesItsCallers() throws {
    let current = withPrivateHelper.replacingOccurrences(
        of: "private func discount(_ cents: Int) -> Int { cents }",
        with: "private func discount(_ cents: Int) -> Int { cents - 100 }")
    guard let plan = plan(withPrivateHelper, current) else { return }

    // The caller's own body did not change. It is replaced anyway, because
    // that is the only way the new implementation reaches anything: replacing
    // some callers and not others would leave two versions live at once.
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
    #expect(plan.carried.map(\.displayName) == ["discount(_:) (Int)"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    // Carried under its own name and its own access level: a replaced body
    // that says `discount(cents)` then resolves to this copy, because the
    // original is invisible to the patch module.
    #expect(source.contains("private func discount(_ cents: Int) -> Int { cents - 100 }"))
    #expect(source.contains("@_dynamicReplacement(for: total())"))
}

/// The bug this machinery also fixes. Only the internal body changed; the
/// private helper it calls did not. Without carrying the helper the patch
/// failed at COMPILE with "cannot find 'discount' in scope", which is what
/// editing any body that called a private helper used to do.
@Test func aPatchedBodyCarriesThePrivateHelpersItCalls() throws {
    let current = withPrivateHelper.replacingOccurrences(
        of: #"{ "\(discount(cents))" }"#, with: #"{ "total \(discount(cents))" }"#)
    guard let plan = plan(withPrivateHelper, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
    #expect(plan.carried.map(\.displayName) == ["discount(_:) (Int)"])
}

@Test func aPrivateChangeReachedFromAnInitialiserIsRefused() {
    let baseline = """
    private func discount(_ cents: Int) -> Int { cents }

    struct Order {
        var cents: Int
        init() { cents = discount(1000) }
        func total() -> String { "\\(cents)" }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ cents }", with: "{ cents - 100 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("discount"))
    #expect(reason.contains("initialiser"))
}

@Test func aPrivateChangeReachedFromAStoredPropertyIsRefused() {
    let baseline = """
    private func discount(_ cents: Int) -> Int { cents }

    struct Order {
        var cents = discount(1000)
        func total() -> String { "\\(cents)" }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ cents }", with: "{ cents - 100 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("discount"))
}

@Test func aFileWithAPrivateProtocolWillNotCarry() {
    let baseline = """
    private protocol Rule { func check() -> Bool }

    struct Order {
        private func discount() -> Int { 0 }
        func total() -> String { "\\(discount())" }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ 0 }", with: "{ 100 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("witness table"))
}

@Test func aPrivateHelperCanBeRenamed() throws {
    let current = withPrivateHelper
        .replacingOccurrences(of: "discount", with: "reduction")
    guard let plan = plan(withPrivateHelper, current) else { return }
    #expect(plan.carried.map(\.simpleName) == ["reduction"])
    #expect(plan.replacements.map(\.displayName) == ["Order.total()"])
}

@Test func aRemovedPrivateHelperStillInUseIsRefused() {
    let current = withPrivateHelper
        .replacingOccurrences(of: "private func discount(_ cents: Int) -> Int { cents }\n", with: "")
    guard let reason = refusal(withPrivateHelper, current) else { return }
    #expect(reason.contains("discount"))
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
    #expect(plan.carried.map(\.simpleName) == ["dollars"])

    let source = try ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("func dollars(_ cents: Int) -> String"))
}

/// Adding a declaration nothing calls yet changes nothing a running process
/// could observe, and FR-13 says a patch that replaces nothing must not be
/// reported as a reload. The edit is not lost: the baseline only advances when
/// a patch lands, so the addition is still pending when the call arrives.
@Test func anAddedHelperNothingCallsIsPending() {
    let baseline = """
    struct Order {
        func total() -> String { "x" }
    }
    """
    let current = """
    struct Order {
        func total() -> String { "x" }
        func dollars() -> String { "y" }
    }
    """
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected noChange")
        return
    }
}

// MARK: - Comments

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

@Test func aCommentInsideABodyIsNotAChangeEither() {
    let baseline = #"struct S { func f() -> String { "x" } }"#
    let current = """
    struct S {
        func f() -> String {
            // explain the thing
            "x"
        }
    }
    """
    guard case .noChange = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected noChange")
        return
    }
}

// MARK: - Where carrying is not allowed
//
// Every case below was found by review after the carry path was written, and
// each one is a way for a carried copy to be reached, or not reached, by
// something the name analysis does not see.

/// A carried copy sits in an extension, where it is statically dispatched. If
/// the name is overridden in the file, a replaced caller reaches the copy
/// instead of the subclass's version --- measured as a process quietly running
/// the base class's implementation while the reload was reported as successful.
@Test func aFileLocalMemberOverriddenInTheFileIsNotCarried() {
    let baseline = """
    class Base {
        fileprivate func tick() -> String { "base" }
        func run() -> String { "run " + tick() }
    }
    class Sub: Base {
        override fileprivate func tick() -> String { "sub" }
    }
    """
    let current = baseline.replacingOccurrences(of: #""run ""#, with: #""RUN ""#)
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("tick"))
    #expect(reason.contains("overridden"))
}

/// A default argument compiles into a generator function of its own, which no
/// patch replaces. Changing a private helper called from one used to report a
/// successful reload and change nothing.
@Test func aPrivateHelperInADefaultArgumentIsRefused() {
    let baseline = """
    private func base() -> Int { 10 }
    struct Cart {
        func total(_ n: Int = base()) -> Int { n }
        func run() -> Int { total() }
    }
    """
    let current = baseline.replacingOccurrences(of: "-> Int { 10 }", with: "-> Int { 20 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("base"))
}

/// A patch cannot name a `private` stored property, and there is no copy to
/// name instead: a copy would be separate storage, not the same bytes. This has
/// to be refused while the reason is still legible, rather than emitted and
/// left to fail at COMPILE against source the developer never wrote.
@Test func aPrivateStoredPropertyReadByAPatchedBodyIsRefused() {
    let baseline = """
    struct Cart {
        private var cents = 100
        func total() -> Int { cents }
    }
    """
    let current = baseline.replacingOccurrences(of: "{ cents }", with: "{ cents + 1 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("cents"))
    #expect(reason.contains("private"))
}

/// A member of a `private extension` is file-local without saying so. Reading
/// only its own modifiers filed it as patchable, claiming a replacement key it
/// does not have.
@Test func aPrivateExtensionMemberIsCarried() throws {
    let baseline = """
    struct Cart { var cents = 1 }
    private extension Cart {
        func fee() -> Int { 1 }
    }
    extension Cart { func total() -> Int { cents + fee() } }
    """
    let current = baseline.replacingOccurrences(of: "func fee() -> Int { 1 }",
                                                with: "func fee() -> Int { 5 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.carried.map(\.simpleName) == ["fee"])
    #expect(plan.replacements.map(\.displayName) == ["Cart.total()"])
}

/// A file-local type is diverted whole into the residue, so an edit inside one
/// is refused by the residue comparison at the top of `classify` rather than by
/// any of the guards below it.
///
/// Asserting the reason is the point. Written as a bare call that discarded the
/// result, this passed while pinning nothing: a review found it was taking the
/// generic residue path and not the carry-route-ends path its own comment
/// claimed, so a regression in the latter would not have failed it.
@Test func anEditInsideAPrivateTypeIsRefusedByTheResidue() {
    let baseline = """
    private struct Helper {
        func compute() -> Int { 1 }
    }
    struct Cart { func total() -> Int { Helper().compute() } }
    """
    let current = baseline.replacingOccurrences(of: "func compute() -> Int { 1 }",
                                                with: "func compute() -> Int { 2 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("outside a replaceable declaration"))
}

@Test func aBodyThatNamesAPrivateTypeIsRefused() {
    let baseline = """
    private struct Helper {
        func compute() -> Int { 1 }
    }
    struct Cart { func total() -> Int { Helper().compute() } }
    """
    let current = baseline.replacingOccurrences(of: "{ Helper().compute() }",
                                                with: "{ Helper().compute() + 1 }")
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("Helper"))
}

/// `private(set)` restricts the setter and leaves the declaration as visible as
/// it was written, so it has a replacement key like any other computed
/// property. Reading the keyword without its detail filed it as file-local, and
/// a `private(set)` property nothing else in the file named then classified as
/// `noChange` --- a real edit, silently dropped.
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
    let current = baseline.replacingOccurrences(of: "get { storage }", with: "get { storage * 2 }")
    guard let plan = plan(baseline, current) else { return }
    #expect(plan.replacements.map(\.displayName) == ["Store.total"])
    #expect(plan.carried.isEmpty)
}

/// The witness-table guard used to run before the two closures that populate
/// `carried`, so it only ever saw declarations the diff put there directly. A
/// witness pulled in transitively --- because a replaced body happens to name it
/// --- went straight past.
@Test func theWitnessGuardSeesTransitivelyCarriedDeclarations() {
    let baseline = """
    private protocol Rule { func check() -> Bool }

    struct Impl: Rule {
        private func check() -> Bool { true }
    }

    func total() -> String { "x" }
    """
    let current = baseline.replacingOccurrences(of: #"func total() -> String { "x" }"#,
                                                with: #"func total() -> String { Impl().check() ? "y" : "x" }"#)
    guard let reason = refusal(baseline, current) else { return }
    #expect(reason.contains("witness table"))
}

// MARK: - What the comparison key must and must not see

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

// MARK: - Facts the indexing walk cannot see
//
// The walk stops descending at a file-local type, at an `#if` block, and at a
// function body, and summarises what is inside as residue. That is right for
// deciding what changed and wrong for the facts the guards read: an `override`
// is still an override wherever it is written. Each of these was measured
// reaching a running process and displacing a subclass's implementation while
// the reload reported success.

private func hidden(_ wrapper: (String) -> String) -> String {
    """
    class Base {
        fileprivate func tag() -> String { "base" }
        func describe() -> String { "tag=\\(tag())" }
    }
    \(wrapper("""
    final class Sub: Base {
        override fileprivate func tag() -> String { "sub" }
    }
    """))
    """
}

private func refuseHiddenOverride(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let current = source.replacingOccurrences(of: #""tag=\#\(tag())""#, with: #""TAG=\#\(tag())""#)
    #expect(current != source, "fixture did not apply", sourceLocation: sourceLocation)
    guard case .rebuildRequired(let reason) = ChangeClassifier.classify(baseline: source, current: current) else {
        Issue.record("expected rebuildRequired", sourceLocation: sourceLocation)
        return
    }
    #expect(reason.contains("tag"), sourceLocation: sourceLocation)
}

@Test func anOverrideInsideAFileLocalTypeIsSeen() {
    refuseHiddenOverride(hidden { "private enum NS {\n\($0)\n}" })
}

@Test func anOverrideInsideAConditionalBlockIsSeen() {
    refuseHiddenOverride(hidden { "#if canImport(Foundation)\n\($0)\n#endif" })
}

@Test func anOverrideInsideAFunctionBodyIsSeen() {
    refuseHiddenOverride(hidden { "func make() -> Base {\n\($0)\n    return Sub()\n}" })
}

@Test func anOverrideInAPlainNamespaceIsSeen() {
    refuseHiddenOverride(hidden { "enum NS {\n\($0)\n}" })
}

// MARK: - File-local declarations the carry route never reached
//
// Every one of these is a way to be `private` and not end up in `local`. The
// index used to list the ways and kept missing one, so the set is now derived
// by subtraction: declared file-local, and not carried.

private func refuseMention(_ baseline: String, _ current: String, naming name: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .rebuildRequired(let reason) = ChangeClassifier.classify(baseline: baseline, current: current) else {
        Issue.record("expected rebuildRequired", sourceLocation: sourceLocation)
        return
    }
    #expect(reason.contains(name), "reason was: \(reason)", sourceLocation: sourceLocation)
}

/// A call site spells an operator with an operator token, not an identifier.
/// Collecting only identifiers left a private operator invisible to the guards,
/// and the patch silently rebound the call to a generic overload.
@Test func aPrivateOperatorIsSeenAtItsCallSite() {
    let baseline = """
    infix operator <+>: AdditionPrecedence
    func <+> <T>(a: T, b: T) -> String { "generic" }
    struct Money { var cents = 0 }
    private func <+> (a: Money, b: Money) -> String { "cents=\\(a.cents + b.cents)" }
    struct Till {
        func total(_ a: Money, _ b: Money) -> String { a <+> b }
    }
    """
    refuseMention(baseline, baseline.replacingOccurrences(of: "{ a <+> b }", with: #"{ "total " + (a <+> b) }"#),
                  naming: "<+>")
}

@Test func aPrivateOpaqueReturningHelperIsSeen() {
    let baseline = """
    struct Box {
        private func rows() -> some Sequence<Int> { [1, 2] }
        func show() -> String { "\\(Array(rows()))" }
    }
    """
    refuseMention(baseline, baseline.replacingOccurrences(of: #"{ "\#\(Array(rows()))" }"#,
                                                          with: #"{ "rows \#\(Array(rows()))" }"#),
                  naming: "rows")
}

@Test func aPrivateCommaSeparatedBindingIsSeen() {
    let baseline = """
    struct Box {
        private var lo = 1, hi = 9
        func span() -> Int { hi - lo }
    }
    """
    // `hi`, not `lo`: the guard reports the first matching mention in sorted
    // order, which is what makes the message reproducible.
    refuseMention(baseline, baseline.replacingOccurrences(of: "{ hi - lo }", with: "{ hi - lo + 1 }"),
                  naming: "hi")
}

@Test func twoPrivateDeclarationsCollidingOnOneIdentityAreSeen() {
    let baseline = """
    struct Box {
        private static func format(_ v: Int) -> String { "s\\(v)" }
        private func format(_ v: Int) -> String { "i\\(v)" }
        func show() -> String { format(1) }
    }
    """
    refuseMention(baseline, baseline.replacingOccurrences(of: "{ format(1) }", with: "{ format(2) }"),
                  naming: "format")
}

/// `extension Helper` carries no `private` of its own, but extending a private
/// type gives its members that access level all the same --- and the patch
/// writes `extension Helper {` around them, naming a type it cannot see.
@Test func anExtensionOfAPrivateTypeIsSeen() {
    let baseline = """
    private struct Helper {
        func compute() -> Int { 1 }
    }
    extension Helper {
        func f() -> Int { 1 }
    }
    struct Cart { func total() -> Int { Helper().f() } }
    """
    refuseMention(baseline, baseline.replacingOccurrences(of: "func f() -> Int { 1 }",
                                                          with: "func f() -> Int { 2 }"),
                  naming: "Helper")
}
