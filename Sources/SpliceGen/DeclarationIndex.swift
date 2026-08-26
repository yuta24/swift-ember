import Foundation
import SwiftSyntax
import SwiftParser

/// A declaration this tool is willing to replace or to carry into a patch,
/// together with everything needed to decide whether it changed and to
/// regenerate it.
public struct PatchableDeclaration: Sendable {
    /// Stable across edits: nesting path plus the declarator. Two declarations
    /// with the same identity in old and new source are the same declaration.
    public let identity: String
    /// The type to extend, or nil for a top-level function.
    public let contextPath: String?
    /// What goes inside `@_dynamicReplacement(for:)`.
    public let replacementTarget: String
    /// Everything except the body, with trivia normalised. A change here is an
    /// ABI-relevant change and is not hot patchable.
    public let signature: String
    /// The body, with trivia normalised. A change here alone is the hot patch
    /// case.
    public let body: String
    /// The original node, reused as the template when generating.
    let node: DeclSyntax
    /// What a human should see. `identity` carries parameter types so that
    /// overloads stay distinct, which is not what belongs in a CLI line.
    public let displayName: String
    /// The declared name with nothing around it.
    ///
    /// Used for one question: whether a declaration the edit *added* overloads
    /// a name that already exists. Adding `kind(_: Int)` beside `kind(_: Any)`
    /// changes what every existing call to `kind` resolves to, including from
    /// bodies the edit did not touch and the patch does not replace.
    public let simpleName: String
    /// How many replaceable entities this declaration emits.
    ///
    /// One for a function. For a computed property it is one per accessor, and
    /// the difference matters: FR-13 compares what the patch asked for against
    /// what the loaded image says it carries, and the image counts accessors.
    /// Measured, a `var x: T { get set }` contributes two records for one
    /// declaration, so counting declarations reported every get/set property
    /// edit as a reload nobody could confirm.
    public let replacementCount: Int

    /// Whether this declaration could be *added* by a patch.
    ///
    /// False for an `override`, which an extension cannot declare, and for an
    /// `@objc` member, which would have to join the class's Objective-C method
    /// list rather than an extension. Only consulted for declarations the edit
    /// introduced; anything already in the binary is replaced, not added.
    public let carryable: Bool
}

/// A declaration that exists but is out of scope, recorded so a change to it
/// produces a specific reason rather than a generic rejection.
public struct UnsupportedDeclaration: Sendable {
    public let identity: String
    public let reason: String
    public let fingerprint: String
}

public struct FileIndex: Sendable {
    /// Declarations that can be replaced in the running process.
    public let patchable: [String: PatchableDeclaration]
    public let unsupported: [String: UnsupportedDeclaration]
    /// The file's imports, verbatim and in order. A patch is compiled on its
    /// own, so a body that mentions `VStack` needs the `import SwiftUI` its
    /// original file had; without them the patch fails at COMPILE with
    /// "cannot find type in scope", which reads like the tool's bug.
    public let imports: [String]
    /// Everything else in the file, hashed, so that a change nobody indexed
    /// still forces a rebuild instead of passing unnoticed.
    public let residue: String
    /// Whether anything in the file is declared `private` or `fileprivate`.
    ///
    /// Decides one line of the generated patch. A patch reaches a file-local
    /// declaration only through `@_private(sourceFile:)`, and that import fails
    /// to compile against a module not built for private imports -- so it is
    /// emitted for the files that need it and left out of the files that do
    /// not, which keeps a project that has not yet added the build setting
    /// working for everything except its private code.
    public let declaresFileLocal: Bool
}

/// Walks a source file and sorts its declarations into "can be replaced",
/// "can be carried", "cannot, and here is why", and "not a declaration we
/// model".
///
/// Deliberately syntactic. DESIGN.md section 7.4 says not to reach for
/// compiler internals until simpler mechanisms fail, and for body-only changes
/// the syntax is enough.
/// What the index is willing to consider, beyond what it can prove.
public struct ClassifierPolicy: Sendable {
    /// Allow declarations returning an opaque result type.
    ///
    /// Off by default and dangerous on: changing the concrete type behind
    /// `some P` compiles and loads without a diagnostic and is then undefined
    /// (DESIGN.md 12.7). `View` is the one protocol measured to be different,
    /// because it carries `@_typeEraser(DebugReplaceableView)` and every
    /// `some View` is already erased to that concrete type. This switch exists
    /// so that claim can be tested against a running app rather than argued
    /// about; see DESIGN.md 13.
    public var allowOpaqueResultTypes = false

    public init(allowOpaqueResultTypes: Bool = false) {
        self.allowOpaqueResultTypes = allowOpaqueResultTypes
    }

    public static let `default` = ClassifierPolicy()

    /// Reads the switch from the environment so a spike can be run without a
    /// build of its own. Not a supported interface.
    public static var fromEnvironment: ClassifierPolicy {
        ClassifierPolicy(
            allowOpaqueResultTypes: ProcessInfo.processInfo.environment["SPLICE_EXPERIMENTAL_SWIFTUI"] == "1")
    }
}

/// Accumulates one file's index.
///
/// A value rather than four `inout` parameters threaded through every visit:
/// the rules about what displaces what --- a duplicate identity demoting both
/// copies, a rejection displacing an earlier patchable --- have to hold for
/// every map, and they only hold in one place if there is only one place.
private struct IndexBuilder {
    var patchable: [String: PatchableDeclaration] = [:]
    var unsupported: [String: UnsupportedDeclaration] = [:]
    var residue: [String] = []

    /// Records a declaration this index will replace or carry.
    ///
    /// Two declarations that reduce to the same identity cannot be told apart,
    /// so neither is usable. Both are demoted, and the fingerprint carries each
    /// of them, so a change to either still forces a rebuild.
    mutating func add(_ declaration: PatchableDeclaration, fingerprint: String) {
        let identity = declaration.identity
        if let existing = displace(identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing + "|" + fingerprint)
            return
        }
        patchable[identity] = declaration
    }

    /// Records a declaration this index will not touch.
    ///
    /// The identity also goes into the residue, in document order, because the
    /// unsupported map is keyed and therefore order-blind. Storage layout
    /// follows declaration order, so swapping two stored properties is a real
    /// change -- and without this it read as no change at all, which is the
    /// worst answer available: the developer sees nothing happen and is not
    /// told why.
    ///
    /// Patchable and file-local declarations are deliberately left out of this.
    /// Moving a method around has no effect on a running process, and forcing a
    /// rebuild for a pure code reshuffle would be noise.
    mutating func reject(_ identity: String, _ reason: String, _ fingerprint: String) {
        residue.append("unsupported:" + identity)
        if let existing = displace(identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing + "|" + fingerprint)
            return
        }
        unsupported[identity] = UnsupportedDeclaration(
            identity: identity, reason: reason, fingerprint: fingerprint)
    }

    /// Anything already filed under this identity, removed and returned as its
    /// fingerprint, or nil if the identity is new.
    private mutating func displace(_ identity: String) -> String? {
        if let existing = unsupported.removeValue(forKey: identity) { return existing.fingerprint }
        if let existing = patchable.removeValue(forKey: identity) { return existing.signature + existing.body }
        return nil
    }

    mutating func note(_ text: String) {
        residue.append(text)
    }

    private func duplicateReason(_ identity: String) -> String {
        "two declarations share the identity \(identity); this index cannot tell them apart"
    }
}

public enum DeclarationIndexer {
    public static func index(source: String,
                             policy: ClassifierPolicy = .default) -> FileIndex {
        let file = Parser.parse(source: source)
        var builder = IndexBuilder()

        // Whether the file needs a private import is a question about the whole
        // file, not about any one declaration. A member of a `private
        // extension` carries no modifier of its own, so asking each declaration
        // in turn answered no and the patch was generated without the import
        // it needed --- rejected at COMPILE with "replaced function could not
        // be found", which reads as a missing key rather than a missing line.
        let detector = FileLocalDetector(viewMode: .sourceAccurate)
        detector.walk(file)

        let imports = collectImports(file.statements.map(\.item))
        let importsSwiftUI = imports.contains { moduleName(of: $0) == "SwiftUI" }

        walk(members: file.statements.map(\.item), context: [], policy: policy,
             importsSwiftUI: importsSwiftUI, into: &builder)

        // Not sorted: order is part of the fingerprint. Sorting made a pure
        // reordering of declarations -- enum cases, say -- invisible.
        return FileIndex(patchable: builder.patchable,
                         unsupported: builder.unsupported, imports: imports,
                         residue: builder.residue.joined(separator: "\n"),
                         declaresFileLocal: detector.found)
    }

    private static func walk(members: [CodeBlockItemSyntax.Item], context: [String],
                             policy: ClassifierPolicy, importsSwiftUI: Bool,
                             into builder: inout IndexBuilder) {
        for item in members {
            guard case .decl(let decl) = item else {
                builder.note(normalise(item))
                continue
            }
            visit(decl, context: context, policy: policy, importsSwiftUI: importsSwiftUI,
                  into: &builder)
        }
    }

    private static func visit(_ decl: DeclSyntax, context: [String],
                              policy: ClassifierPolicy, importsSwiftUI: Bool,
                              into builder: inout IndexBuilder) {
        // Before the branch below, not after: ProtocolDeclSyntax conforms to
        // both DeclGroupSyntax and NamedDeclSyntax, so it would otherwise be
        // walked as if it were a concrete type and its requirements mistaken
        // for implementations.
        if let proto = decl.as(ProtocolDeclSyntax.self) {
            // Requirements have no bodies worth replacing, and changing one
            // changes the witness table. Default implementations live in
            // extensions and are handled there.
            builder.note(normalise(proto))
            return
        }

        if let type = decl.asProtocol(NamedDeclSyntax.self) as? (any DeclGroupSyntax & NamedDeclSyntax) {
            // class / struct / enum / actor: recurse, and fingerprint the
            // declaration head so that changing inheritance or generics is seen.
            let name = type.name.text

            let head = head(of: type)
            builder.note(normalise(head))
            walk(members: type.memberBlock.members.map { .decl($0.decl) },
                 context: context + [name], policy: policy, importsSwiftUI: importsSwiftUI,
                 into: &builder)
            return
        }

        if let ext = decl.as(ExtensionDeclSyntax.self) {
            // The where clause is part of the context, not decoration. Two
            // constrained extensions of the same type declare different
            // members, and generating into a bare `extension Array` would drop
            // the constraint their bodies rely on.
            var name = ext.extendedType.trimmedDescription
            if let constraint = ext.genericWhereClause {
                name += " " + constraint.trimmedDescription
            }
            let head = head(of: ext)
            builder.note(normalise(head))
            walk(members: ext.memberBlock.members.map { .decl($0.decl) },
                 context: [name], policy: policy, importsSwiftUI: importsSwiftUI,
                 into: &builder)
            return
        }

        if let function = decl.as(FunctionDeclSyntax.self) {
            record(function: function, context: context, policy: policy,
                   importsSwiftUI: importsSwiftUI, into: &builder)
            return
        }

        if let variable = decl.as(VariableDeclSyntax.self) {
            record(variable: variable, context: context, policy: policy,
                   importsSwiftUI: importsSwiftUI, into: &builder)
            return
        }

        builder.note(normalise(decl))
    }

    /// Imports, including those inside `#if`.
    ///
    /// A file that reaches UIKit through `#if canImport(UIKit)` still needs the
    /// import in its patch. The conditional is preserved rather than flattened,
    /// because the patch compile is given the same `-D` set as the app and will
    /// resolve it the same way.
    ///
    /// A conditional block is emitted by rewriting the node with its
    /// non-import statements removed and printing it whole. Reassembling the
    /// `#if` scaffolding by hand produced `##if`, one `#endif` per clause, and
    /// a top-level `#else`, none of which is Swift.
    private static func collectImports(_ items: [CodeBlockItemSyntax.Item]) -> [String] {
        items.compactMap(retainingImports).map(\.trimmedDescription)
    }

    /// The declaration with everything that is not an import removed, or nil if
    /// nothing is left.
    private static func retainingImports(_ item: CodeBlockItemSyntax.Item) -> DeclSyntax? {
        guard case .decl(let decl) = item else { return nil }
        if decl.is(ImportDeclSyntax.self) { return decl }

        guard var conditional = decl.as(IfConfigDeclSyntax.self) else { return nil }

        var kept = false
        conditional.clauses = IfConfigClauseListSyntax(conditional.clauses.map { clause in
            var clause = clause
            guard case .statements(let statements)? = clause.elements else {
                clause.elements = nil
                return clause
            }
            // Recursive, so a nested conditional import is not lost.
            let imports = statements.compactMap { statement -> CodeBlockItemSyntax? in
                guard let retained = retainingImports(statement.item) else { return nil }
                return CodeBlockItemSyntax(item: .decl(retained))
            }
            kept = kept || !imports.isEmpty
            // Empty clauses are kept rather than dropped: removing the `#if`
            // branch would leave a list that starts with `#else`.
            clause.elements = imports.isEmpty ? nil : .statements(CodeBlockItemListSyntax(imports))
            return clause
        })

        return kept ? DeclSyntax(conditional) : nil
    }

    /// The module an import statement names, ignoring any `import struct Foo.Bar`
    /// specifier and any attributes.
    static func moduleName(of statement: String) -> String {
        guard let path = statement.split(separator: " ").last else { return statement }
        return String(path.split(separator: ".").first ?? path)
    }

    // MARK: - Functions

    private static func record(function: FunctionDeclSyntax, context: [String],
                               policy: ClassifierPolicy, importsSwiftUI: Bool,
                               into builder: inout IndexBuilder) {
        let labels = function.signature.parameterClause.parameters.map { parameter in
            (parameter.firstName.text == "_" ? "_" : parameter.firstName.text) + ":"
        }.joined()
        // What goes inside @_dynamicReplacement(for:), which is label-only.
        let target = "\(function.name.text)(\(labels))"
        // Identity has to separate overloads that share their labels, so it
        // carries the parameter types too. Keying on labels alone made two
        // overloads collide in the dictionary, and the edit to whichever one
        // lost simply disappeared.
        let types = function.signature.parameterClause.parameters
            .map { compact($0.type) }.joined(separator: ",")
        let identity = (context + ["\(target)[\(types)]"]).joined(separator: ".")

        var withoutBody = function.detached
        withoutBody.body = nil
        let signature = normalise(withoutBody)

        guard let body = function.body else {
            builder.reject(identity, "declaration has no body", signature)
            return
        }

        let fingerprint = signature + normalise(body)

        if let reason = rejection(attributes: function.attributes, modifiers: function.modifiers) {
            builder.reject(identity, reason, fingerprint)
            return
        }

        if let literal = magicLiteral(in: Syntax(body)) {
            builder.reject(identity, magicLiteralReason(literal), fingerprint)
            return
        }

        if isOperator(function.name) {
            // Operators do get replacement keys (Appendix A), but the spelling
            // of the @_dynamicReplacement(for:) target for one is not something
            // this generator knows, and guessing would produce a patch that
            // either fails to compile or replaces the wrong thing.
            builder.reject(identity, "operator declarations are not supported by this generator", fingerprint)
            return
        }

        let returnType = function.signature.returnClause?.type
        if containsOpaqueType(returnType) {
            let erasedView = isErasedSwiftUIView(returnType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                builder.reject(identity, erasedView ? swiftUIBodyReason : opaqueReason, fingerprint)
                return
            }
        }

        let carryable = isCarryable(attributes: function.attributes, modifiers: function.modifiers)

        // A file-local declaration that cannot be copied cannot be reached at
        // all: it has no replacement key either. Say which of the two it is.
        let display = (context + [target]).joined(separator: ".")
            + (types.isEmpty ? "" : " (\(types))")

        builder.add(PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: target,
            signature: signature,
            body: normalise(body),
            node: DeclSyntax(function),
            displayName: display,
            simpleName: function.name.text,
            replacementCount: 1,
            carryable: carryable),
            fingerprint: fingerprint)
    }

    // MARK: - Properties

    private static func record(variable: VariableDeclSyntax, context: [String],
                               policy: ClassifierPolicy, importsSwiftUI: Bool,
                               into builder: inout IndexBuilder) {


        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else {
            // A comma-separated declaration (`var a = 1, b = 2`) or a tuple
            // pattern (`let (a, b) = ...`). Not modelled, so it goes to the
            // residue verbatim like any other construct this index does not
            // understand. Returning silently here meant adding a property to a
            // comma-separated list changed the type's layout and the tool
            // answered "nothing changed" -- the one failure mode with no
            // recovery, because the developer is never told to rebuild.
            builder.note(normalise(variable))
            return
        }

        let identity = (context + [name]).joined(separator: ".")

        guard let accessors = binding.accessorBlock, !isStored(accessors) else {
            // A stored property, including the willSet/didSet form, which has
            // an accessor block but real backing storage all the same. Its
            // layout is the reason section 12.2 exists, so any change forces a
            // rebuild.
            //
            // A file-local one is also unreachable: no key to replace it, and
            // no copy possible, since a copy would be a second allocation
            // rather than the same storage. A body that reads it cannot be
            // patched at all, which is why the name is recorded.
            builder.reject(identity, "stored property; changing one changes the type's layout",
                           normalise(variable))
            return
        }

        var withoutBody = variable.detached
        withoutBody.bindings = PatternBindingListSyntax([binding.detached.with(\.accessorBlock, nil)])
        // Which accessors exist is signature, not body. Gaining a setter leaves
        // `var v: Int` untouched, so it read as a body change: the patch loaded,
        // reported a reload, and the setter was dead --- the original key has no
        // setter for it to bind to.
        let signature = normalise(withoutBody) + "|" + accessorShape(accessors)
        let fingerprint = signature + normalise(accessors)

        if let reason = rejection(attributes: variable.attributes, modifiers: variable.modifiers) {
            builder.reject(identity, reason, fingerprint)
            return
        }

        if let literal = magicLiteral(in: Syntax(accessors)) {
            builder.reject(identity, magicLiteralReason(literal), fingerprint)
            return
        }

        let declaredType = binding.typeAnnotation?.type
        if containsOpaqueType(declaredType) {
            let erasedView = isErasedSwiftUIView(declaredType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                builder.reject(identity, erasedView ? swiftUIBodyReason : opaqueReason, fingerprint)
                return
            }
        }

        let carryable = isCarryable(attributes: variable.attributes, modifiers: variable.modifiers)
        builder.add(PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: name,
            signature: signature,
            body: normalise(accessors),
            node: DeclSyntax(variable),
            displayName: identity,
            simpleName: name,
            replacementCount: accessorCount(accessors),
            carryable: carryable),
            fingerprint: fingerprint)
    }

    /// How many accessors a property declares, which is how many replacement
    /// records it emits. A bare `{ ... }` is one implicit getter.
    private static func accessorCount(_ accessors: AccessorBlockSyntax) -> Int {
        switch accessors.accessors {
        case .getter: return 1
        case .accessors(let list): return max(list.count, 1)
        }
    }

    /// The accessors a property declares, as a stable string.
    private static func accessorShape(_ accessors: AccessorBlockSyntax) -> String {
        switch accessors.accessors {
        case .getter:
            return "get"
        case .accessors(let list):
            return list.map { $0.accessorSpecifier.text }.sorted().joined(separator: ",")
        }
    }

    /// willSet/didSet do not make a property computed. Swift synthesises real
    /// storage for them, so they belong with stored properties.
    private static func isStored(_ accessors: AccessorBlockSyntax) -> Bool {
        guard case .accessors(let list) = accessors.accessors else { return false }
        return list.contains { accessor in
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.willSet), .keyword(.didSet): true
            default: false
            }
        }
    }

    // MARK: - Reasons

    static let opaqueReason = """
        returns an opaque result type; changing the concrete type behind `some` \
        compiles and loads without a diagnostic and is then undefined at runtime
        """

    static func magicLiteralReason(_ literal: String) -> String {
        """
        its body uses \(literal), which expands against the declaration the patch \
        emits rather than this one, so a reload would quietly change what it reports
        """
    }

    /// The source-location literals, which a patch cannot preserve.
    ///
    /// `#function` in a replaced body expands to the generated name --- measured
    /// as `label()` becoming `splice_g1_label____()` --- and `#fileID` to the
    /// patch's own file. Nothing warns, and the wrong value lands in exactly
    /// the code that exists to say where you are.
    ///
    /// This catches the literal written in the body. It cannot catch one
    /// arriving through a callee's default argument, such as
    /// `func log(_ m: String, function: String = #function)`, which is
    /// evaluated at the call site and so also expands in the patch. That case
    /// is recorded in PRD.md section 5 rather than detected.
    private static func magicLiteral(in node: Syntax) -> String? {
        let finder = MagicLiteralFinder(viewMode: .sourceAccurate)
        finder.walk(node)
        return finder.found
    }

    /// `View` is the measured exception, and it fails a different way.
    ///
    /// It carries `@_typeEraser(DebugReplaceableView)`, so `some View` is
    /// already a concrete type and changing the tree shape is not the
    /// undefined-behaviour case above --- the patch loads, and a direct call to
    /// `body` really does reach it. SwiftUI's own rendering does not, so the
    /// edit silently changes nothing on screen. Measured in DESIGN.md 13; a
    /// silent no-op is the outcome this tool exists to avoid reporting as
    /// success.
    static let swiftUIBodyReason = """
        returns `some View`; the patch would load and change nothing, because \
        SwiftUI does not evaluate a view body through the replacement
        """

    /// Whether this is the one shape measured to be erased, and therefore the
    /// only one the experimental switch may lift.
    ///
    /// Exact, not a substring test, and both halves are load-bearing.
    ///
    /// The type must be `some View` at the root. Erasure applies to a whole
    /// opaque return type, not to an opaque position inside one:
    /// `func f() -> (some View)?` measures as `Optional<Text>`, unerased, and
    /// replacing it with a different tree crashes the process. Treating it as
    /// the safe case would have told the developer their edit was harmless and
    /// then handed them a SIGSEGV.
    ///
    /// And the file must import SwiftUI, because the guarantee comes from
    /// `@_typeEraser` on Apple's `View`, not from the spelling. A protocol of
    /// one's own named `View`, or a `some ViewModelProtocol`, has no eraser and
    /// is the undefined-behaviour case. Calling either of them harmless is an
    /// invitation to turn the switch on.
    private static func isErasedSwiftUIView(_ type: TypeSyntax?, importsSwiftUI: Bool) -> Bool {
        guard importsSwiftUI, let type else { return false }
        guard let opaque = type.as(SomeOrAnyTypeSyntax.self),
              opaque.someOrAnySpecifier.tokenKind == .keyword(.some) else { return false }
        return opaque.constraint.trimmedDescription == "View"
            || opaque.constraint.trimmedDescription == "SwiftUI.View"
    }

    private static func isOperator(_ name: TokenSyntax) -> Bool {
        switch name.tokenKind {
        case .binaryOperator, .prefixOperator, .postfixOperator: true
        default: false
        }
    }

    /// True if the type mentions `some` anywhere. Deliberately an
    /// over-approximation: an opaque result type whose underlying type changes
    /// is accepted by both the compiler and the loader and is then undefined at
    /// runtime (DESIGN.md section 12.7), so this is the only place it can be
    /// stopped, and stopping too much only costs a rebuild.
    private static func containsOpaqueType(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        let finder = OpaqueTypeFinder(viewMode: .sourceAccurate)
        finder.walk(type)
        return finder.found
    }

    // MARK: - Eligibility

    /// The declaration kinds measured to be outside `-enable-implicit-dynamic`
    /// (DESIGN.md section 12.8), plus the ones this generator cannot express.
    ///
    /// `override` is not among them. The replacement is a separate declaration
    /// bound to the original's key, not an override itself, so an extension
    /// accepts it -- and the original is then reached through the base class,
    /// through `objc_msgSend`, and from a body calling `super`. Pinned by
    /// `fixtures/Cases/override-*`.
    private static func rejection(attributes: AttributeListSyntax,
                                  modifiers: DeclModifierListSyntax) -> String? {
        for attribute in attributes {
            guard case .attribute(let attribute) = attribute else { continue }
            switch attribute.attributeName.trimmedDescription {
            case "inlinable":
                return "@inlinable declarations are not made dynamic by -enable-implicit-dynamic"
            case "_transparent":
                return "@_transparent declarations are not made dynamic by -enable-implicit-dynamic"
            case "_alwaysEmitIntoClient":
                return "@_alwaysEmitIntoClient declarations are emitted into callers"
            default:
                continue
            }
        }
        return nil
    }

    /// A bare `private` or `fileprivate`, and not `private(set)`.
    ///
    /// The detail is the whole check. `private(set)` restricts the setter and
    /// leaves the declaration itself as visible as it was written, so it has a
    /// replacement key and is patchable like any other computed property.
    /// Reading the keyword alone filed it as file-local, and a `private(set)`
    /// computed property that nothing else in the file named then classified
    /// as `noChange` --- a real edit, silently dropped.
    static func isFileLocal(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            guard modifier.detail == nil else { return false }
            switch modifier.name.tokenKind {
            case .keyword(.private), .keyword(.fileprivate): return true
            default: return false
            }
        }
    }

    static func isOverride(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.override) }
    }

    /// Whether a copy of this declaration can be emitted into a patch.
    ///
    /// An `override` cannot: an extension may not declare one, and a copy
    /// placed there would be statically dispatched rather than take the
    /// original's place in the vtable. An `@objc` member cannot either: its
    /// callers go through the Objective-C runtime to the class's method list,
    /// which still holds the original, so a copy would sit there unused while
    /// the tool reported success.
    static func isCarryable(attributes: AttributeListSyntax,
                            modifiers: DeclModifierListSyntax) -> Bool {
        if isOverride(modifiers) { return false }
        for attribute in attributes {
            guard case .attribute(let attribute) = attribute else { continue }
            if attribute.attributeName.trimmedDescription == "objc" { return false }
        }
        return true
    }

    // MARK: - Helpers

    /// The declaration head, without members: attributes, modifiers, name,
    /// generics, inheritance. Changing any of it is ABI-relevant.
    private static func head(of decl: some DeclGroupSyntax) -> some DeclGroupSyntax {
        var copy = decl.detached
        copy.memberBlock = MemberBlockSyntax(members: MemberBlockItemListSyntax([]))
        return copy
    }

    /// A type as a human reads it, with layout removed: `[String : Int]` and
    /// `[String: Int]` both come out `[String:Int]`.
    ///
    /// Separate from `normalise` because this one is seen. It goes into the
    /// identity, which carries parameter types to keep overloads apart, and
    /// from there into the line the CLI prints --- where `normalise`'s control
    /// characters turned `(Int)` into `(Int\u{02})`.
    static func compact(_ node: some SyntaxProtocol) -> String {
        node.tokens(viewMode: .sourceAccurate).map(\.text).joined()
    }

    /// A comparison key for a piece of syntax: the shape of the tree and the
    /// text of its tokens.
    ///
    /// Built from tokens rather than from printed source, and that is the whole
    /// point. Collapsing whitespace in the *text* also collapsed it inside
    /// string literals, so `"Total:  9"` and `"Total: 9"` compared equal and
    /// the save was reported as no change at all --- the silent failure with no
    /// recovery, since the developer is never told anything happened. Token
    /// text is exact; only the trivia between tokens is ignored.
    ///
    /// The node kinds carry the one whitespace distinction Swift cares about: a
    /// statement boundary. `return` followed by a newline is not the same
    /// program as `return` followed by an expression, and comparing tokens
    /// alone made them equal. The parser has already resolved that difference
    /// into two different trees, so reading the tree is both cheaper and more
    /// accurate than trying to re-derive it from whitespace --- which is what
    /// an earlier version did, and it reported adding a `// MARK:` as a change,
    /// because a comment on its own line brings a newline with it.
    ///
    /// Comments are ignored because they are trivia and nothing here reads
    /// trivia. No rewrite is involved, which is what lets the generator emit
    /// the original source, comments and all --- and a comment that separates
    /// two tokens keeps separating them. Removing it from the tree turned
    /// `1 +/*x*/+2` into `1 ++2`, which is not Swift.
    ///
    /// This key is never parsed. It only has to differ whenever the program
    /// differs, and be equal whenever the program is the same.
    static func normalise(_ node: some SyntaxProtocol) -> String {
        let builder = KeyBuilder(viewMode: .sourceAccurate)
        builder.walk(node)
        return builder.key
    }

    static func normalise(_ item: CodeBlockItemSyntax.Item) -> String {
        switch item {
        case .decl(let decl): normalise(decl)
        case .stmt(let stmt): normalise(stmt)
        case .expr(let expr): normalise(expr)
        }
    }
}

private final class OpaqueTypeFinder: SyntaxVisitor {
    var found = false

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.someOrAnySpecifier.tokenKind == .keyword(.some) { found = true }
        return .visitChildren
    }
}

private final class MagicLiteralFinder: SyntaxVisitor {
    var found: String?

    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        guard found == nil else { return .skipChildren }
        switch node.tokenKind {
        case .poundAvailable, .poundUnavailable:
            break
        case .pound:
            break
        default:
            let text = node.text
            if text.hasPrefix("#"), MagicLiteralFinder.names.contains(String(text.dropFirst())) {
                found = text
            }
        }
        return .skipChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, MagicLiteralFinder.names.contains(node.macroName.text) {
            found = "#" + node.macroName.text
        }
        return .visitChildren
    }

    static let names: Set<String> = [
        "function", "file", "fileID", "filePath", "line", "column", "dsohandle",
    ]
}

/// True if anything in the file is declared `private` or `fileprivate`.
///
/// Modifiers anywhere, not declarations of a particular kind: the one on a
/// `private extension` or a `private struct` governs every member inside it
/// without appearing on any of them. `private(set)` is excluded, since it
/// restricts the setter and leaves the declaration as visible as it was
/// written.
private final class FileLocalDetector: SyntaxVisitor {
    var found = false

    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
        if DeclarationIndexer.isFileLocal(DeclModifierListSyntax([node])) { found = true }
        return .skipChildren
    }
}

/// Builds the comparison key: every token's text, and a marker at every
/// statement boundary.
///
/// Only `CodeBlockItemSyntax` is marked, not every node kind. Marking all of
/// them also worked and cost 23 ms more on a 2,000-line file, because naming a
/// `SyntaxKind` allocates a string per node. Statement boundaries are the only
/// structure whitespace can change --- `return` on its own line against
/// `return x` is two statements against one --- and the parser has already
/// decided that, so this is the whole of what the tree adds over the tokens.
private final class KeyBuilder: SyntaxVisitor {
    var key = ""

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        key += "\u{1}"
        return .visitChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        key += "\u{2}"
        key += token.text
        return .skipChildren
    }
}
