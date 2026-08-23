import Testing
@testable import SpliceGen

/// For each declaration kind the classifier is willing to call body-only,
/// prove that the patch the generator writes actually compiles, loads, and
/// takes effect. A verdict nobody executes is a guess.

private func expectReload(_ baseline: String, _ current: String,
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

private func probe(_ body: String) -> String {
    "func probe() async throws -> [String] { \(body) }"
}

@Test func topLevelFunction() {
    let baseline = """
    func subject() -> String { "old" }
    \(probe("[subject()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #""old""#, with: #""new""#),
                 before: ["old"], after: ["new"])
}

@Test func classMethodKeepsInstanceState() {
    let baseline = """
    class Counter {
        var value = 0
        func label() -> String { "old" }
    }
    nonisolated(unsafe) let counter: Counter = { let c = Counter(); c.value = 42; return c }()
    \(probe(#"[counter.label(), "value=\(counter.value)"]"#))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #"{ "old" }"#, with: #"{ "new" }"#),
                 before: ["old", "value=42"], after: ["new", "value=42"])
}

@Test func structMethod() {
    let baseline = """
    struct Price { var value: Int
        func formatted() -> String { "old(\\(value))" } }
    let price = Price(value: 10)
    \(probe("[price.formatted()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old(", with: "new("),
                 before: ["old(10)"], after: ["new(10)"])
}

@Test func mutatingStructMethod() {
    let baseline = """
    struct Accumulator { var total = 0
        mutating func add() { total += 1 } }
    nonisolated(unsafe) var accumulator = Accumulator()
    \(probe(#"{ accumulator.add(); return ["total=\(accumulator.total)"] }()"#))
    """
    // 1001, not 1000: the same process and the same value carry across the
    // patch, so the pre-patch increment is still in the total.
    expectReload(baseline, baseline.replacingOccurrences(of: "total += 1", with: "total += 1000"),
                 before: ["total=1"], after: ["total=1001"])
}

@Test func enumMethod() {
    let baseline = """
    enum Kind { case a, b
        func name() -> String { "old(\\(self))" } }
    let kind = Kind.b
    \(probe("[kind.name()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old(", with: "new("),
                 before: ["old(b)"], after: ["new(b)"])
}

@Test func computedProperty() {
    let baseline = """
    struct Box { var raw = 21
        var doubled: Int { raw * 2 } }
    let box = Box()
    \(probe(#"["doubled=\(box.doubled)"]"#))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "raw * 2", with: "raw * 100"),
                 before: ["doubled=42"], after: ["doubled=2100"])
}

@Test func staticMethod() {
    let baseline = """
    enum Registry { static func lookup() -> String { "old" } }
    \(probe("[Registry.lookup()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #""old""#, with: #""new""#),
                 before: ["old"], after: ["new"])
}

@Test func genericFunction() {
    let baseline = """
    func describe<T: CustomStringConvertible>(_ value: T) -> String { "old(\\(value))" }
    \(probe("[describe(7)]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old(", with: "new("),
                 before: ["old(7)"], after: ["new(7)"])
}

@Test func protocolExtensionDefault() {
    let baseline = """
    protocol Describable { func describe() -> String }
    extension Describable { func describe() -> String { "old" } }
    struct Thing: Describable {}
    let thing = Thing()
    let erased: any Describable = Thing()
    \(probe("[thing.describe(), erased.describe()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #"{ "old" }"#, with: #"{ "new" }"#),
                 before: ["old", "old"], after: ["new", "new"])
}

@Test func asyncThrowsFunction() {
    let baseline = """
    func fetch() async throws -> String { "old" }
    \(probe("[try await fetch()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #""old""#, with: #""new""#),
                 before: ["old"], after: ["new"])
}

@Test func actorMethodKeepsActorState() {
    let baseline = """
    actor Session { var hits = 7
        func summary() -> String { "old(\\(hits))" } }
    let session = Session()
    \(probe("[await session.summary()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old(", with: "new("),
                 before: ["old(7)"], after: ["new(7)"])
}

@Test func mainActorMethod() {
    let baseline = """
    @MainActor final class ViewModel { var token = "kept"
        func render() -> String { "old(\\(token))" } }
    @MainActor let viewModel = ViewModel()
    \(probe("[await viewModel.render()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old(", with: "new("),
                 before: ["old(kept)"], after: ["new(kept)"])
}

@Test func nestedTypeMethod() {
    let baseline = """
    enum Outer { struct Inner { func f() -> String { "old" } } }
    let inner = Outer.Inner()
    \(probe("[inner.f()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: #""old""#, with: #""new""#),
                 before: ["old"], after: ["new"])
}

@Test func constrainedExtensionKeepsItsConstraint() {
    // The case a review found broken: both extensions collapsed into one
    // unconstrained `extension Array`, and the generated patch would not build.
    let baseline = """
    extension Array where Element == Int {
        func describe() -> String { "old-int" }
    }
    extension Array where Element == String {
        func describe() -> String { "old-string" }
    }
    let ints = [1, 2]
    let strings = ["a"]
    \(probe("[ints.describe(), strings.describe()]"))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old-int", with: "new-int"),
                 before: ["old-int", "old-string"], after: ["new-int", "old-string"])
}

@Test func overloadsSharingLabelsArePatchedIndividually() {
    // The other case a review found: these collided on one identity key and the
    // edit to whichever lost the dictionary write vanished.
    let baseline = """
    struct Converter {
        func run(value: Int) -> String { "old-int" }
        func run(value: String) -> String { "old-string" }
    }
    let converter = Converter()
    \(probe(#"[converter.run(value: 1), converter.run(value: "x")]"#))
    """
    expectReload(baseline, baseline.replacingOccurrences(of: "old-int", with: "new-int"),
                 before: ["old-int", "old-string"], after: ["new-int", "old-string"])
}

@Test func severalDeclarationsInOneGeneration() {
    let baseline = """
    struct Pair {
        func a() -> String { "old-a" }
        func b() -> String { "old-b" }
    }
    let pair = Pair()
    \(probe("[pair.a(), pair.b()]"))
    """
    let current = baseline
        .replacingOccurrences(of: "old-a", with: "new-a")
        .replacingOccurrences(of: "old-b", with: "new-b")
    expectReload(baseline, current, before: ["old-a", "old-b"], after: ["new-a", "new-b"])
}
