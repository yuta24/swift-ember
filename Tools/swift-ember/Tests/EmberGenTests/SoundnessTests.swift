import Foundation
import Testing
@testable import EmberGen

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
    case .hotPatch(let plan):
        Issue.record("accepted as hot patchable: \(plan.replacements.map(\.identity))",
                     sourceLocation: sourceLocation)
    case .noChange:
        Issue.record("reported no change at all", sourceLocation: sourceLocation)
    }
}

private struct CompilerResult {
    let status: Int32
    let output: String
}

private func runSwiftc(_ arguments: [String]) throws -> CompilerResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CompilerResult(
        status: process.terminationStatus,
        output: String(data: data, encoding: .utf8) ?? "")
}

private func compileModule(named name: String, source: String, in directory: URL) throws {
    let sourceURL = directory.appendingPathComponent("\(name).swift")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    let result = try runSwiftc([
        "-parse-as-library", "-emit-module", "-module-name", name,
        "-I", directory.path,
        "-emit-module-path", directory.appendingPathComponent("\(name).swiftmodule").path,
        sourceURL.path,
    ])
    guard result.status == 0 else {
        throw CompilerFixtureError.module(name: name, output: result.output)
    }
}

private func typecheck(_ source: String, named name: String,
                       in directory: URL) throws -> CompilerResult {
    let sourceURL = directory.appendingPathComponent(name)
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    return try runSwiftc(["-typecheck", "-I", directory.path, sourceURL.path])
}

private enum CompilerFixtureError: Error, CustomStringConvertible {
    case module(name: String, output: String)

    var description: String {
        switch self {
        case .module(let name, let output):
            "could not compile fixture module \(name):\n\(output)"
        }
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
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("a default implementation is an ordinary body")
        return
    }
    let declarations = plan.replacements
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
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected the Int overload to be recognised")
        return
    }
    let declarations = plan.replacements
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
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected the Int-constrained extension to be recognised")
        return
    }
    let declarations = plan.replacements
    let source = try! ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
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
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a nested method to be patchable")
        return
    }
    let declarations = plan.replacements
    #expect(declarations[0].contextPath == "Outer.Inner")
    let source = try! ReplacementGenerator.generate(module: "M", generation: 1, plan: plan)
    #expect(source.contains("extension Outer.Inner {"))
}

// MARK: - SwiftUI

@Test func aSwiftUIBodyIsRefusedForWhatItDoesToTheProcess() {
    // Refused three times now, and only this reason is measured. The patch is
    // not unsafe to load -- `View` carries a type eraser -- and it is not
    // inert either: a replaced body runs when SwiftUI evaluates that view, on
    // screen. What it does is abort the process when the body's concrete type
    // changes and the view is a row of a List, because the eraser's storage is
    // generic and the graph downcasts it to the type it saw first. DESIGN.md
    // 13.1 has the transcript.
    expectRebuild(
        "import SwiftUI\nstruct Screen: View { var body: some View { Text(\"old\") } }",
        "import SwiftUI\nstruct Screen: View { var body: some View { Text(\"new\") } }",
        because: "aborts the process")
}

@Test func aSwiftUIBodyIsRefusedWithItsOwnReasonAndNotTheGenericOne() {
    // The wording matters: telling somebody their `some View` edit is the
    // undefined-behaviour case would be wrong about where it fails, and
    // telling them it does nothing would be wrong about whether it runs.
    let baseline = "import SwiftUI\nstruct Screen: View { var body: some View { Text(\"old\") } }"
    let index = DeclarationIndexer.index(source: baseline)
    let reason = index.unsupported.values.first { $0.identity.contains("body") }?.reason ?? ""
    #expect(reason.contains("List"), "expected the measured reason, got: \(reason)")
    #expect(!reason.contains("undefined at runtime"))
}

@Test func anOptedInSwiftUIBodyIsHotPatchable() throws {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View {
            Text("old")
                .emberable()
        }
    }
    """
    let current = baseline.replacingOccurrences(
        of: "Text(\"old\")",
        with: "VStack { Text(\"new\"); Text(\"second\") }")

    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("the measured SwiftUI opt-in was refused")
        return
    }
    #expect(plan.replacements.count == 1)
    // The image carries the getter and its opaque-result descriptor. The UI
    // fixture reads two from the loaded replacement section.
    #expect(plan.replacements[0].replacementCount == 2)
    let generated = try ReplacementGenerator.generate(
        module: "M", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    #expect(generated.contains(".emberable()"))
    #expect(generated.contains("import EmberSwiftUI"))
    #expect(generated.components(separatedBy: "SwiftUI.AnyView").count - 1 == 1,
            "the edited body must be compiler-checked")
    let inferred = generated.range(of: "_inferred =")
    let validated = generated.range(of: ": SwiftUI.AnyView = __swift_ember_current_")
    #expect(inferred != nil, "the outer call must be inferred without an expected type")
    #expect(validated != nil, "the inferred value must then be checked as AnyView")
    if let inferred, let validated {
        #expect(inferred.lowerBound < validated.lowerBound)
    }
}

@Test func anOptedInBodyMayLiveInAnExtensionInTheSameFile() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View { @ObserveEmber private var ember }
    extension Screen {
        var body: some View { Text("old").emberable() }
    }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch = classify(baseline, current) else {
        Issue.record("the observer on the nominal type was not found by its extension")
        return
    }
}

@Test func aLookalikeSwiftUIEmberAPIWithoutTheModuleImportIsRefused() {
    let baseline = """
    import SwiftUI
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "does not import")
}

@Test func aQualifiedLookalikeObserverIsNotOurOptIn() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View {
        @Other.ObserveEmber private var ember
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "@ObserveEmber")
}

@Test func aConditionalEmberSwiftUIImportDoesNotProveTheOptInBinding() {
    let baseline = """
    import SwiftUI
    #if canImport(EmberSwiftUI)
    import EmberSwiftUI
    #endif
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "does not import")
}

@Test func aLocalEmberableDeclarationCannotShadowTheBoundary() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    extension Text { func emberable() -> Text { self } }
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "reserved")
}

@Test func anImportedEmberableOverloadFailsTheUncontextualizedBoundaryCheck() throws {
    // This models a dependency that adds a more-specific overload for Text.
    // The app's ordinary expression selects it and returns Text. A direct
    // AnyView annotation can steer overload resolution back to the generic
    // Ember overload, which is precisely the context the generator must not
    // add to the original expression.
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-overload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    try compileModule(
        named: "BoundaryViews",
        source: """
        public protocol View {}
        public struct AnyView: View {
            public init<V: View>(_ value: V) {}
        }
        public struct Text: View {
            public init(_ value: String) {}
        }
        """,
        in: work)
    try compileModule(
        named: "EmberBoundary",
        source: """
        import BoundaryViews
        public extension BoundaryViews.View {
            func emberable() -> BoundaryViews.AnyView { BoundaryViews.AnyView(self) }
        }
        """,
        in: work)
    try compileModule(
        named: "ImportedFeature",
        source: """
        import BoundaryViews
        public extension BoundaryViews.Text {
            func emberable() -> BoundaryViews.Text { self }
        }
        """,
        in: work)

    let contextual = try typecheck(
        """
        import BoundaryViews
        import EmberBoundary
        import ImportedFeature
        func original() -> some BoundaryViews.View {
            BoundaryViews.Text("old").emberable()
        }
        func oldGeneratedShape() {
            let _: BoundaryViews.AnyView = BoundaryViews.Text("new").emberable()
        }
        """,
        named: "Contextual.swift",
        in: work)
    #expect(contextual.status == 0,
            "the contextual form should expose the unsafe overload steering: \(contextual.output)")

    let uncontextualized = try typecheck(
        """
        import BoundaryViews
        import EmberBoundary
        import ImportedFeature
        func generatedShape() {
            let inferred = BoundaryViews.Text("new").emberable()
            let _: BoundaryViews.AnyView = inferred
        }
        """,
        named: "Uncontextualized.swift",
        in: work)
    #expect(uncontextualized.status != 0,
            "the imported Self-returning overload must make the patch fail before load")
    #expect(uncontextualized.output.contains("cannot convert value of type"),
            "unexpected compiler diagnostic: \(uncontextualized.output)")
}

@Test func emberableWithoutTheObserverIsRefused() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View {
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "@ObserveEmber")
}

@Test func aStaticObserveEmberDoesNotPromiseViewInvalidation() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View {
        @ObserveEmber static var ember
        var body: some View { Text("old").emberable() }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "@ObserveEmber")
}

@Test func emberableMustEraseTheWholeBody() {
    let baseline = """
    import SwiftUI
    import EmberSwiftUI
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View {
            VStack { Text("old").emberable() }
        }
    }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "old", with: "new"),
                  because: "outermost expression")
}

@Test func addingTheSwiftUIOptInRequiresARebuildFirst() {
    let baseline = """
    import SwiftUI
    struct Screen: View { var body: some View { Text("old") } }
    """
    let current = """
    import SwiftUI
    struct Screen: View {
        @ObserveEmber private var ember
        var body: some View { Text("new").emberable() }
    }
    """
    expectRebuild(baseline, current, because: "outside a replaceable declaration")
}

@Test func anOpaqueReturnThatIsNotAViewIsStillRefused() {
    // The eraser is what makes `some View` safe, and it is specific to `View`.
    // Everything else behind `some` is still the undefined-behaviour case.
    let baseline = """
    protocol Shape {}
    struct Circle: Shape {}
    struct Square: Shape {}
    struct S { var thing: some Shape { Circle() } }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "{ Circle() }", with: "{ Square() }"),
                  because: "opaque result type")
}

@Test func aViewBodyIsNotMarkedWhenTheFileDoesNotImportSwiftUI() {
    // The guarantee comes from Apple's `View`, not from the spelling. A
    // protocol of one's own called `View` has no eraser, so this stays a
    // refusal rather than becoming a note.
    expectRebuild(
        "protocol View {}\nstruct Text: View { init(_ s: String) {} }\nstruct S { var body: some View { Text(\"old\") } }",
        "protocol View {}\nstruct Text: View { init(_ s: String) {} }\nstruct S { var body: some View { Text(\"new\") } }",
        because: "opaque result type")
}

@Test func generatedPatchesCarryTheOriginalImports() throws {
    let baseline = """
    import Foundation
    import SwiftUI
    struct S { func f() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a hot patch")
        return
    }
    let declarations = plan.replacements
    let source = try ReplacementGenerator.generate(
        module: "M", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    #expect(source.contains("import Foundation"))
    #expect(source.contains("import SwiftUI"))
    #expect(source.contains("@testable import M"))
}

// MARK: - Which opaque types the SwiftUI exception covers

@Test func onlyAWholeSomeViewCountsAsErased() {
    // `(some View)?` is an opaque position inside a type, not an opaque return
    // type, and it is not erased: it measures as Optional<Text>, and replacing
    // it crashes the process. Calling that harmless would have been the worst
    // possible message, since the harmless wording is what invites the switch.
    expectRebuild(
        "import SwiftUI\nstruct H { func maybe() -> (some View)? { Text(\"old\") } }",
        "import SwiftUI\nstruct H { func maybe() -> (some View)? { Text(\"new\") } }",
        because: "undefined at runtime")
}

@Test func aProtocolMerelySpelledWithViewIsNotTheSafeCase() {
    // The guarantee comes from @_typeEraser on Apple's View, not from the name.
    expectRebuild(
        "protocol P {}\nstruct A: P {}\nstruct B: P {}\nstruct S { var vm: some P { A() } }",
        "protocol P {}\nstruct A: P {}\nstruct B: P {}\nstruct S { var vm: some P { B() } }",
        because: "undefined at runtime")
}

@Test func someViewWithoutSwiftUIIsNotTheSafeCase() {
    // A View of one's own has no eraser.
    expectRebuild(
        "protocol View {}\nstruct S: View {}\nstruct T: View {}\nstruct H { var body: some View { S() } }",
        "protocol View {}\nstruct S: View {}\nstruct T: View {}\nstruct H { var body: some View { T() } }",
        because: "undefined at runtime")
}


// MARK: - Imports

@Test func aModuleWhoseNameIsAPrefixIsNotMistakenForTheAppModule() throws {
    // `contains(" Fixture")` dropped `import FixtureKit`, which is exactly the
    // "cannot find type in scope" failure carrying imports is meant to prevent.
    let baseline = """
    import Foundation
    import FixtureKit
    struct S { func f() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a hot patch")
        return
    }
    let declarations = plan.replacements
    let source = try ReplacementGenerator.generate(
        module: "Fixture", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    #expect(source.contains("import FixtureKit"))
    // The app module itself arrives as @testable and must not be repeated.
    let plainSelfImport = source.split(separator: "\n").filter { $0 == "import Fixture" }
    #expect(plainSelfImport.isEmpty)
}

@Test func conditionalImportsAreCarriedWithTheirCondition() throws {
    let baseline = """
    import Foundation
    #if canImport(UIKit)
    import UIKit
    #endif
    struct S { func f() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a hot patch")
        return
    }
    let declarations = plan.replacements
    let source = try ReplacementGenerator.generate(
        module: "M", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    // Compared as whole lines. `contains("#if canImport(UIKit)")` was
    // satisfied by the "##if canImport(UIKit)" a hand-assembled `#if` head
    // produced, so this assertion passed while the feature was broken in every
    // case it applied to.
    let lines = source.split(separator: "\n").map(String.init)
    #expect(lines.contains("#if canImport(UIKit)"))
    #expect(lines.contains("import UIKit"))
    #expect(lines.contains("#endif"))
    #expect(lines.filter { $0 == "#endif" }.count == 1)
}

@Test func anIfElseImportKeepsOneEndif() throws {
    // One `#endif` per clause is the other half of the same mistake, and it
    // needs a two-clause case to show up at all.
    let baseline = """
    #if canImport(UIKit)
    import UIKit
    #else
    import AppKit
    #endif
    struct S { func f() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a hot patch")
        return
    }
    let declarations = plan.replacements
    let source = try ReplacementGenerator.generate(
        module: "M", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    let lines = source.split(separator: "\n").map(String.init)
    #expect(lines.filter { $0 == "#endif" }.count == 1)
    #expect(lines.contains("#else"))
    #expect(!lines.contains { $0.hasPrefix("##") })
}

@Test func submoduleImportsSurvive() throws {
    let baseline = """
    import struct Foundation.Data
    struct S { func f() -> String { "old" } }
    """
    let current = baseline.replacingOccurrences(of: "old", with: "new")
    guard case .hotPatch(let plan) = classify(baseline, current) else {
        Issue.record("expected a hot patch")
        return
    }
    let declarations = plan.replacements
    let source = try ReplacementGenerator.generate(
        module: "M", generation: 1, plan: plan,
        imports: DeclarationIndexer.index(source: current).imports)
    #expect(source.contains("import struct Foundation.Data"))
}

/// A declaration-level import is not an import of SwiftUI.
///
/// `import struct SwiftUI.Text` names the module in its path without bringing
/// `View` into scope, so a file that declares a `View` protocol of its own has
/// `some View` bodies that carry no type eraser. Reading the import as text
/// took the first component of the last token and called that SwiftUI, and the
/// resulting patch compiled, loaded, and killed the process with EXC_BAD_ACCESS
/// on the witness table -- measured on the host and on the Simulator.
@Test func aDeclarationLevelImportDoesNotMakeABodyErased() {
    let baseline = """
    import struct SwiftUI.Text
    protocol View { func describe() -> String }
    struct Small: View { var x: Int; func describe() -> String { "small" } }
    struct Big: View { var a = 0; var b = ""; func describe() -> String { "big" } }
    struct Screen { var body: some View { Small(x: 7) } }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "{ Small(x: 7) }", with: "{ Big() }"),
                  because: "opaque result type")
}

/// And an import inside a `#if` is one.
///
/// The text form rendered the whole conditional block as a single import
/// statement, so its module name was never SwiftUI and a body in such a file
/// was refused with the wrong reason -- the generic undefined-behaviour one
/// rather than the measured SwiftUI one. Both are refusals, so this costs a
/// diagnostic rather than correctness, but the diagnostic is what a developer
/// acts on.
@Test func aConditionalImportOfSwiftUIStillCounts() {
    let source = """
    #if canImport(SwiftUI)
    import SwiftUI
    #endif
    struct Screen: View { var body: some View { Text("old") } }
    """
    let index = DeclarationIndexer.index(source: source)
    let reason = index.unsupported.values.first { $0.identity.contains("body") }?.reason ?? ""
    #expect(reason.contains("List"), "expected the SwiftUI reason, got: \(reason)")
}


/// Nothing lifts the refusal on an unerased opaque return any more.
///
/// There used to be an environment switch. It existed so the SwiftUI claim
/// could be measured against a running app; that measurement is done, and what
/// the switch would still do is let the daemon compile a patch whose runtime
/// behaviour is undefined and load it into somebody's process. The fixtures
/// measure that behaviour with hand-written patches instead, which is where it
/// belongs.
@Test func anUnerasedOpaqueReturnHasNoEscapeHatch() {
    let baseline = """
    protocol Shape {}
    struct Circle: Shape {}
    struct Square: Shape {}
    struct S { var thing: some Shape { Circle() } }
    """
    expectRebuild(baseline,
                  baseline.replacingOccurrences(of: "{ Circle() }", with: "{ Square() }"),
                  because: "opaque result type")

    // The nested case too: `(some View)?` is an opaque position inside a type,
    // which erasure does not reach.
    let nested = "import SwiftUI\nstruct H { func maybe() -> (some View)? { Text(\"old\") } }"
    expectRebuild(nested, nested.replacingOccurrences(of: "old", with: "new"),
                  because: "opaque result type")
}
