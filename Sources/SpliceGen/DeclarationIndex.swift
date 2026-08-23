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
public enum DeclarationIndexer {
    public static func index(source: String) -> FileIndex {
        let file = Parser.parse(source: source)
        var patchable: [String: PatchableDeclaration] = [:]
        var unsupported: [String: UnsupportedDeclaration] = [:]
        var residue: [String] = []

        walk(members: file.statements.map(\.item), context: [], into: &patchable,
             unsupported: &unsupported, residue: &residue)

        // Not sorted: order is part of the fingerprint. Sorting made a pure
        // reordering of declarations -- enum cases, say -- invisible.
        return FileIndex(patchable: patchable, unsupported: unsupported,
                         residue: residue.joined(separator: "\n"))
    }

    private static func walk(members: [CodeBlockItemSyntax.Item], context: [String],
                             into patchable: inout [String: PatchableDeclaration],
                             unsupported: inout [String: UnsupportedDeclaration],
                             residue: inout [String]) {
        for item in members {
            guard case .decl(let decl) = item else {
                residue.append(normalise(item.description))
                continue
            }
            visit(decl, context: context, into: &patchable, unsupported: &unsupported, residue: &residue)
        }
    }

    private static func visit(_ decl: DeclSyntax, context: [String],
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
                 context: context + [name], into: &patchable,
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
                 context: [name], into: &patchable,
                 unsupported: &unsupported, residue: &residue)
            return
        }

        if let function = decl.as(FunctionDeclSyntax.self) {
            record(function: function, context: context, into: &patchable, unsupported: &unsupported)
            return
        }

        if let variable = decl.as(VariableDeclSyntax.self) {
            record(variable: variable, context: context, into: &patchable, unsupported: &unsupported)
            return
        }

        residue.append(normalise(decl.description))
    }

    // MARK: - Functions

    private static func record(function: FunctionDeclSyntax, context: [String],
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration]) {
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
                   into: &patchable, unsupported: &unsupported)
            return
        }

        let fingerprint = signature + normalise(body.description)

        if let reason = rejection(attributes: function.attributes, modifiers: function.modifiers) {
            reject(identity, reason, fingerprint, into: &patchable, unsupported: &unsupported)
            return
        }

        if isOperator(function.name) {
            // Operators do get replacement keys (Appendix A), but the spelling
            // of the @_dynamicReplacement(for:) target for one is not something
            // this generator knows, and guessing would produce a patch that
            // either fails to compile or replaces the wrong thing.
            reject(identity, "operator declarations are not supported by this generator",
                   fingerprint, into: &patchable, unsupported: &unsupported)
            return
        }

        if containsOpaqueType(function.signature.returnClause?.type) {
            reject(identity, opaqueReason, fingerprint, into: &patchable, unsupported: &unsupported)
            return
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
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration]) {
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else {
            return
        }

        let identity = (context + [name]).joined(separator: ".")

        guard let accessors = binding.accessorBlock, !isStored(accessors) else {
            // A stored property, including the willSet/didSet form, which has
            // an accessor block but real backing storage all the same. Its
            // layout is the reason section 12.2 exists, so any change forces a
            // rebuild.
            reject(identity, "stored property; changing one changes the type's layout",
                   normalise(variable.description), into: &patchable, unsupported: &unsupported)
            return
        }

        var withoutBody = variable
        withoutBody.bindings = PatternBindingListSyntax([binding.with(\.accessorBlock, nil)])
        let signature = normalise(withoutBody.description)
        let fingerprint = signature + normalise(accessors.description)

        if let reason = rejection(attributes: variable.attributes, modifiers: variable.modifiers) {
            reject(identity, reason, fingerprint, into: &patchable, unsupported: &unsupported)
            return
        }

        if containsOpaqueType(binding.typeAnnotation?.type) {
            reject(identity, opaqueReason, fingerprint, into: &patchable, unsupported: &unsupported)
            return
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

    private static func reject(_ identity: String, _ reason: String, _ fingerprint: String,
                               into patchable: inout [String: PatchableDeclaration],
                               unsupported: inout [String: UnsupportedDeclaration]) {
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
