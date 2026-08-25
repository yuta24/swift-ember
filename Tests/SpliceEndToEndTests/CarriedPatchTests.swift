import Testing
@testable import SpliceGen

/// What a patch carries with it, run rather than argued about.
///
/// A carried declaration is one the running binary cannot reach: `private`, so
/// invisible outside its file and to the patch module alike, or new, so absent
/// when the binary was linked. The patch emits its own copy under the same
/// name, and Swift resolves a replaced body's reference to that copy.
///
/// `fixtures/Cases/private-via-caller` and `patch-local-declaration` pin the
/// toolchain behaviour by hand. These pin that the generator produces it.

private let order = """
private func discount(_ cents: Int) -> Int { cents }

struct Order {
    var cents = 1000
    func total() -> String { "\\(discount(cents))" }
}

let order = Order()
\(probe("[order.total()]"))
"""

@Test func aPrivateHelperChangeReachesItsCaller() {
    // Only the private helper changed. Its caller is replaced anyway, because
    // that is the only way the new implementation reaches a running process.
    expectReload(order,
                 order.replacingOccurrences(of: "-> Int { cents }", with: "-> Int { cents - 100 }"),
                 before: ["1000"], after: ["900"])
}

/// The failure this fixed rather than added. Before the patch carried private
/// declarations, editing *any* body that called one produced a patch that
/// failed at COMPILE with "cannot find 'discount' in scope" -- an everyday edit
/// that looked like a bug in the tool, because it was.
@Test func aPatchedBodyCanCallAnUnchangedPrivateHelper() {
    expectReload(order,
                 order.replacingOccurrences(of: #"{ "\(discount(cents))" }"#,
                                            with: #"{ "total \(discount(cents))" }"#),
                 before: ["1000"], after: ["total 1000"])
}

@Test func aPrivateComputedPropertyIsCarried() {
    let baseline = """
    struct Order {
        var cents = 1000
        private var fee: Int { 0 }
        func total() -> String { "\\(cents + fee)" }
    }
    let order = Order()
    \(probe("[order.total()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "private var fee: Int { 0 }",
                                                         with: "private var fee: Int { 25 }"),
                 before: ["1000"], after: ["1025"])
}

/// Renaming is a removal and an addition, and a removal is a rebuild: the
/// original stays in the binary and nothing can say what still calls it.
/// Allowing it needed a reference analysis that only existed to serve the carry
/// route, and went with it.
@Test func aRenamedPrivateHelperIsARebuild() {
    do {
        _ = try Loop.run(baseline: order, current: order.replacingOccurrences(of: "discount", with: "reduction"))
        Issue.record("expected the classifier to refuse a rename")
    } catch {
        #expect("\(error)".contains("removed"))
    }
}

@Test func anAddedHelperIsCallableFromAPatchedBody() {
    let baseline = """
    struct Order {
        var cents = 1000
        func total() -> String { "\\(cents)" }
    }
    let order = Order()
    \(probe("[order.total()]"))
    """
    let current = """
    struct Order {
        var cents = 1000
        func total() -> String { dollars(cents) }
        func dollars(_ cents: Int) -> String { "$\\(cents / 100)" }
    }
    let order = Order()
    \(probe("[order.total()]"))
    """
    expectReload(baseline, current, before: ["1000"], after: ["$10"])
}

@Test func aPrivateHelperCallingAnotherPrivateHelperIsCarriedWhole() {
    let baseline = """
    private func rate() -> Int { 10 }
    private func discount(_ cents: Int) -> Int { cents - rate() }

    struct Order {
        var cents = 1000
        func total() -> String { "\\(discount(cents))" }
    }
    let order = Order()
    \(probe("[order.total()]"))
    """
    // Only `rate` changes. `discount` calls it and is itself private, so the
    // patch has to carry both and replace the one declaration above them that
    // it can.
    expectReload(baseline, baseline.replacingOccurrences(of: "private func rate() -> Int { 10 }",
                                                         with: "private func rate() -> Int { 250 }"),
                 before: ["990"], after: ["750"])
}

// MARK: - What the generator must not mangle
//
// Each of these produced a patch that did not build. They fail closed, so no
// process was ever at risk, but the developer is shown a compile error against
// generated source they did not write and told to fix their own file.

/// `@objc(name)` copied verbatim onto the replacement declares a second method
/// with the same Objective-C selector as the original. A bare `@objc` binds
/// through the replacement key just as well, and calls through the original
/// custom selector still arrive.
@Test func aCustomObjCSelectorIsNotCopiedOntoTheReplacement() {
    let baseline = """
    import Foundation
    class Thing: NSObject { @objc(labelText) func label() -> String { "a" } }
    nonisolated(unsafe) let thing = Thing()
    \(probe(#"["direct=\(thing.label())", "sel=\(thing.perform(Selector(("labelText")))?.takeUnretainedValue() as? String ?? "nil")"]"#))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #""a""#, with: #""b""#),
                 before: ["direct=a", "sel=a"], after: ["direct=b", "sel=b"])
}

/// The generator emits the original source, comments included. An earlier
/// version compared declarations by rewriting the tree with comments removed
/// and then generated from that tree, which turned `1 +/*x*/+2` into `1 ++2`.
@Test func aCommentSeparatingTwoOperatorsSurvivesIntoThePatch() {
    let baseline = "struct S { func total() -> Int { 1 +/*x*/+2 } }\nlet s = S()\n"
        + probe(#"["\(s.total())"]"#)
    expectReload(baseline, baseline.replacingOccurrences(of: "+2", with: "+3"),
                 before: ["3"], after: ["4"])
}

/// A member of a `private extension` is file-local without saying so. Filed as
/// patchable, it claimed a replacement key it does not have and the patch was
/// rejected at COMPILE with "replaced function could not be found".
@Test func aPrivateExtensionMemberIsCarriedAndReaches() {
    let baseline = """
    struct Cart { var cents = 1 }
    private extension Cart {
        func fee() -> Int { 1 }
    }
    extension Cart { func total() -> Int { cents + fee() } }
    let cart = Cart()
    \(probe(#"["\(cart.total())"]"#))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "func fee() -> Int { 1 }",
                                                         with: "func fee() -> Int { 5 }"),
                 before: ["2"], after: ["6"])
}

// MARK: - Across generations
//
// A carried declaration lives in the patch dylib and nowhere else, so the
// patch after it has to carry it again. Nothing single-generation could see
// that, and the whole suite was single-generation.

private let extractedHelper = [
    """
    struct Order {
        var cents = 1000
        func total() -> String { "\\(cents)" }
    }
    let order = Order()
    \(probe(#"["\(order.total())"]"#))
    """,
    """
    struct Order {
        var cents = 1000
        func total() -> String { dollars(cents) }
        func dollars(_ c: Int) -> String { "$\\(c / 100)" }
    }
    let order = Order()
    \(probe(#"["\(order.total())"]"#))
    """,
    """
    struct Order {
        var cents = 1000
        func total() -> String { "=" + dollars(cents) }
        func dollars(_ c: Int) -> String { "$\\(c / 100)" }
    }
    let order = Order()
    \(probe(#"["\(order.total())"]"#))
    """,
]

/// Extract a helper, then keep tuning the caller. The second patch names a
/// declaration only the first patch ever contained.
@Test func aCarriedHelperSurvivesTheNextPatch() throws {
    let output = try Loop.runGenerations(extractedHelper)
    #expect(output == ["g0: 1000", "g1: $10", "g2: =$10"], "full output: \(output)")
}

/// Editing the carried helper itself. Its callers were replaced by an earlier
/// patch and call *that* patch's copy, so they have to be re-emitted with it.
@Test func editingACarriedHelperReachesItsEarlierCallers() throws {
    var versions = Array(extractedHelper.prefix(2))
    versions.append(versions[1].replacingOccurrences(of: #""$\#\(c / 100)""#,
                                                     with: #""USD \#\(c / 100)""#))
    let output = try Loop.runGenerations(versions)
    #expect(output == ["g0: 1000", "g1: $10", "g2: USD 10"], "full output: \(output)")
}

/// A private helper, the same shape. This one was a regression: the closure
/// that used to re-carry file-local declarations every generation went with the
/// copy route it served.
@Test func aCarriedPrivateHelperSurvivesTheNextPatch() throws {
    let v0 = """
    struct Order {
        var cents = 1000
        func total() -> String { "\\(cents)" }
    }
    let order = Order()
    \(probe(#"["\(order.total())"]"#))
    """
    let v1 = v0.replacingOccurrences(
        of: #"func total() -> String { "\#\(cents)" }"#,
        with: """
        func total() -> String { dollars(cents) }
            private func dollars(_ c: Int) -> String { "$\\(c / 100)" }
        """)
    let v2 = v1.replacingOccurrences(of: "{ dollars(cents) }", with: #"{ "=" + dollars(cents) }"#)
    let output = try Loop.runGenerations([v0, v1, v2])
    #expect(output == ["g0: 1000", "g1: $10", "g2: =$10"], "full output: \(output)")
}
