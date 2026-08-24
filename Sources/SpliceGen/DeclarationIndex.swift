import Foundation
import SwiftSyntax
import SwiftParser

/// A declaration this tool is willing to replace, together with everything
/// needed to decide whether it changed and to regenerate it.
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
}

/// A declaration that exists but is out of scope, recorded so a change to it
/// produces a specific reason rather than a generic rejection.
public struct UnsupportedDeclaration: Sendable {
    public let identity: String
    public let reason: String
    public let fingerprint: String
}

public struct FileIndex: Sendable {
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
}

/// Walks a source file and sorts its declarations into "can be replaced",
/// "cannot, and here is why", and "not a declaration we model".
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

public enum DeclarationIndexer {
    public static func index(source: String,
                             policy: ClassifierPolicy = .default) -> FileIndex {
        let file = Parser.parse(source: source)
        var patchable: [String: PatchableDeclaration] = [:]
        var unsupported: [String: UnsupportedDeclaration] = [:]
        var residue: [String] = []

        let imports = collectImports(file.statements.map(\.item))
        let importsSwiftUI = imports.contains { moduleName(of: $0) == "SwiftUI" }

        walk(members: file.statements.map(\.item), context: [], policy: policy,
             importsSwiftUI: importsSwiftUI, into: &patchable,
             unsupported: &unsupported, residue: &residue)

        // Not sorted: order is part of the fingerprint. Sorting made a pure
        // reordering of declarations -- enum cases, say -- invisible.
        return FileIndex(patchable: patchable, unsupported: unsupported,
                         imports: imports,
                         residue: residue.joined(separator: "\n"))
    }

    private static func walk(members: [CodeBlockItemSyntax.Item], context: [String],
                             policy: ClassifierPolicy, importsSwiftUI: Bool,
                             into patchable: inout [String: PatchableDeclaration],
                             unsupported: inout [String: UnsupportedDeclaration],
                             residue: inout [String]) {
        for item in members {
            guard case .decl(let decl) = item else {
                residue.append(normalise(item.description))
                continue
            }
            visit(decl, context: context, policy: policy, importsSwiftUI: importsSwiftUI, into: &patchable,
                  unsupported: &unsupported, residue: &residue)
        }
    }

    private static func visit(_ decl: DeclSyntax, context: [String],
                              policy: ClassifierPolicy, importsSwiftUI: Bool,
                              into patchable: inout [String: PatchableDeclaration],
                              unsupported: inout [String: UnsupportedDeclaration],
                              residue: inout [String]) {
        // Before the branch below, not after: ProtocolDeclSyntax conforms to
        // both DeclGroupSyntax and NamedDeclSyntax, so it would otherwise be
        // walked as if it were a concrete type and its requirements mistaken
        // for implementations.
        if let proto = decl.as(ProtocolDeclSyntax.self) {
            // Requirements have no bodies worth replacing, and changing one
            // changes the witness table. Default implementations live in
            // extensions and are handled there.
            residue.append(normalise(proto.description))
            return
        }

        if let type = decl.asProtocol(NamedDeclSyntax.self) as? (any DeclGroupSyntax & NamedDeclSyntax) {
            // class / struct / enum / actor: recurse, and fingerprint the
            // declaration head so that changing inheritance or generics is seen.
            let name = type.name.text
            residue.append(normalise(head(of: type)))
            walk(members: type.memberBlock.members.map { .decl($0.decl) },
                 context: context + [name], policy: policy, importsSwiftUI: importsSwiftUI, into: &patchable,
                 unsupported: &unsupported, residue: &residue)
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
            residue.append(normalise(head(of: ext)))
            walk(members: ext.memberBlock.members.map { .decl($0.decl) },
                 context: [name], policy: policy, importsSwiftUI: importsSwiftUI, into: &patchable,
                 unsupported: &unsupported, residue: &residue)
            return
        }

        if let function = decl.as(FunctionDeclSyntax.self) {
            record(function: function, context: context, policy: policy, importsSwiftUI: importsSwiftUI, into: &patchable,
                   unsupported: &unsupported, residue: &residue)
            return
        }

        if let variable = decl.as(VariableDeclSyntax.self) {
            record(variable: variable, context: context, policy: policy, importsSwiftUI: importsSwiftUI, into: &patchable,
                   unsupported: &unsupported, residue: &residue)
            return
        }

        residue.append(normalise(decl.description))
    }

    /// Imports, including those inside `#if`.
    ///
    /// A file that reaches UIKit through `#if canImport(UIKit)` still needs the
    /// import in its patch. The conditional wrapper is preserved rather than
    /// flattened, because the patch compile is given the same `-D` set as the
    /// app and will resolve it the same way.
    private static func collectImports(_ items: [CodeBlockItemSyntax.Item]) -> [String] {
        items.flatMap { item -> [String] in
            guard case .decl(let decl) = item else { return [] }
            if let importDecl = decl.as(ImportDeclSyntax.self) {
                return [importDecl.trimmedDescription]
            }
            if let conditional = decl.as(IfConfigDeclSyntax.self) {
                return conditional.clauses.flatMap { clause -> [String] in
                    guard case .statements(let statements)? = clause.elements else { return [] }
                    let inner = collectImports(statements.map(\.item))
                    guard !inner.isEmpty else { return [] }
                    let head = "#\(clause.poundKeyword.text)"
                        + (clause.condition.map { " \($0.trimmedDescription)" } ?? "")
                    return [head] + inner + ["#endif"]
                }
            }
            return []
        }
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
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration],
                               residue: inout [String]) {
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
            .map { normalise($0.type.description) }.joined(separator: ",")
        let identity = (context + ["\(target)[\(types)]"]).joined(separator: ".")

        var withoutBody = function
        withoutBody.body = nil
        let signature = normalise(withoutBody.description)

        guard let body = function.body else {
            reject(identity, "declaration has no body", signature,
                   into: &patchable, unsupported: &unsupported, residue: &residue)
            return
        }

        let fingerprint = signature + normalise(body.description)

        if let reason = rejection(attributes: function.attributes, modifiers: function.modifiers) {
            reject(identity, reason, fingerprint, into: &patchable, unsupported: &unsupported, residue: &residue)
            return
        }

        if isOperator(function.name) {
            // Operators do get replacement keys (Appendix A), but the spelling
            // of the @_dynamicReplacement(for:) target for one is not something
            // this generator knows, and guessing would produce a patch that
            // either fails to compile or replaces the wrong thing.
            reject(identity, "operator declarations are not supported by this generator",
                   fingerprint, into: &patchable, unsupported: &unsupported, residue: &residue)
            return
        }

        let returnType = function.signature.returnClause?.type
        if containsOpaqueType(returnType) {
            let erasedView = isErasedSwiftUIView(returnType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                reject(identity, erasedView ? swiftUIBodyReason : opaqueReason,
                       fingerprint, into: &patchable, unsupported: &unsupported, residue: &residue)
                return
            }
        }

        let display = (context + [target]).joined(separator: ".")
            + (types.isEmpty ? "" : " (\(types))")

        insert(PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: target,
            signature: signature,
            body: normalise(body.description),
            node: DeclSyntax(function),
            displayName: display),
            fingerprint: fingerprint, into: &patchable, unsupported: &unsupported)
    }

    // MARK: - Properties

    private static func record(variable: VariableDeclSyntax, context: [String],
                               policy: ClassifierPolicy, importsSwiftUI: Bool,
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration],
                               residue: inout [String]) {
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
            residue.append(normalise(variable.description))
            return
        }

        let identity = (context + [name]).joined(separator: ".")

        guard let accessors = binding.accessorBlock, !isStored(accessors) else {
            // A stored property, including the willSet/didSet form, which has
            // an accessor block but real backing storage all the same. Its
            // layout is the reason section 12.2 exists, so any change forces a
            // rebuild.
            reject(identity, "stored property; changing one changes the type's layout",
                   normalise(variable.description), into: &patchable, unsupported: &unsupported, residue: &residue)
            return
        }

        var withoutBody = variable
        withoutBody.bindings = PatternBindingListSyntax([binding.with(\.accessorBlock, nil)])
        let signature = normalise(withoutBody.description)
        let fingerprint = signature + normalise(accessors.description)

        if let reason = rejection(attributes: variable.attributes, modifiers: variable.modifiers) {
            reject(identity, reason, fingerprint, into: &patchable, unsupported: &unsupported, residue: &residue)
            return
        }

        let declaredType = binding.typeAnnotation?.type
        if containsOpaqueType(declaredType) {
            let erasedView = isErasedSwiftUIView(declaredType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                reject(identity, erasedView ? swiftUIBodyReason : opaqueReason,
                       fingerprint, into: &patchable, unsupported: &unsupported, residue: &residue)
                return
            }
        }

        insert(PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: name,
            signature: signature,
            body: normalise(accessors.description),
            node: DeclSyntax(variable),
            displayName: identity),
            fingerprint: fingerprint, into: &patchable, unsupported: &unsupported)
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

    // MARK: - Insertion

    static let opaqueReason = """
        returns an opaque result type; changing the concrete type behind `some` \
        compiles and loads without a diagnostic and is then undefined at runtime
        """

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

    /// Two declarations that reduce to the same identity cannot be told apart,
    /// so neither is patchable. Both are demoted, and the fingerprint carries
    /// each of them, so a change to either still forces a rebuild.
    private static func insert(_ declaration: PatchableDeclaration, fingerprint: String,
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration]) {
        let identity = declaration.identity
        if let existing = unsupported[identity] {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing.fingerprint + "|" + fingerprint)
            return
        }
        if let existing = patchable.removeValue(forKey: identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing.signature + existing.body + "|" + fingerprint)
            return
        }
        patchable[identity] = declaration
    }

    /// Records a declaration this index will not patch.
    ///
    /// The identity also goes into the residue, in document order, because the
    /// unsupported map is keyed and therefore order-blind. Storage layout
    /// follows declaration order, so swapping two stored properties is a real
    /// change -- and without this it read as no change at all, which is the
    /// worst answer available: the developer sees nothing happen and is not
    /// told why.
    ///
    /// Patchable declarations are deliberately left out of this. Moving a
    /// method around has no effect on a running process, and forcing a rebuild
    /// for a pure code reshuffle would be noise.
    private static func reject(_ identity: String, _ reason: String, _ fingerprint: String,
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration],
                               residue: inout [String]) {
        residue.append("unsupported:" + identity)
        if let existing = unsupported[identity] {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing.fingerprint + "|" + fingerprint)
            return
        }
        if let existing = patchable.removeValue(forKey: identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing.signature + existing.body + "|" + fingerprint)
            return
        }
        unsupported[identity] = UnsupportedDeclaration(
            identity: identity, reason: reason, fingerprint: fingerprint)
    }

    private static func isOperator(_ name: TokenSyntax) -> Bool {
        switch name.tokenKind {
        case .binaryOperator, .prefixOperator, .postfixOperator: true
        default: false
        }
    }

    private static func duplicateReason(_ identity: String) -> String {
        "two declarations share the identity \(identity); this index cannot tell them apart"
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

        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.private), .keyword(.fileprivate):
                return "private and fileprivate declarations get no replacement key and are not visible to @testable import"
            case .keyword(.override):
                return "an override cannot be replaced from an extension"
            default:
                continue
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// The declaration head, without members: attributes, modifiers, name,
    /// generics, inheritance. Changing any of it is ABI-relevant.
    private static func head(of decl: some DeclGroupSyntax) -> String {
        var copy = decl
        copy.memberBlock = MemberBlockSyntax(members: MemberBlockItemListSyntax([]))
        return copy.description
    }

    /// Collapses whitespace so that reindenting a file is not mistaken for an
    /// edit. Comment changes still register, which is conservative in the
    /// right direction.
    static func normalise(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class OpaqueTypeFinder: SyntaxVisitor {
    var found = false

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.someOrAnySpecifier.tokenKind == .keyword(.some) { found = true }
        return .visitChildren
    }
}
