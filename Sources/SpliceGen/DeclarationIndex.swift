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

    public var displayName: String { identity }
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

        return FileIndex(patchable: patchable, unsupported: unsupported,
                         residue: residue.sorted().joined(separator: "\n"))
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
            let name = ext.extendedType.trimmedDescription
            residue.append(normalise(head(of: ext)))
            walk(members: ext.memberBlock.members.map { .decl($0.decl) },
                 context: [name], into: &patchable,
                 unsupported: &unsupported, residue: &residue)
            return
        }

        if let proto = decl.as(ProtocolDeclSyntax.self) {
            // Requirements have no bodies. Default implementations live in
            // extensions and are handled there.
            residue.append(normalise(proto.description))
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
        let target = "\(function.name.text)(\(labels))"
        let identity = (context + [target]).joined(separator: ".")

        var withoutBody = function
        withoutBody.body = nil
        let signature = normalise(withoutBody.description)

        guard let body = function.body else {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: "declaration has no body",
                fingerprint: signature)
            return
        }

        if let reason = rejection(attributes: function.attributes, modifiers: function.modifiers) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: reason,
                fingerprint: signature + normalise(body.description))
            return
        }

        patchable[identity] = PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: target,
            signature: signature,
            body: normalise(body.description),
            node: DeclSyntax(function))
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

        guard let accessors = binding.accessorBlock else {
            // A stored property. Its layout is the reason section 12.2 exists,
            // so any change to one forces a rebuild.
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity,
                reason: "stored property; changing one changes the type's layout",
                fingerprint: normalise(variable.description))
            return
        }

        var withoutBody = variable
        withoutBody.bindings = PatternBindingListSyntax([binding.with(\.accessorBlock, nil)])
        let signature = normalise(withoutBody.description)

        if let reason = rejection(attributes: variable.attributes, modifiers: variable.modifiers) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: reason,
                fingerprint: signature + normalise(accessors.description))
            return
        }

        patchable[identity] = PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: name,
            signature: signature,
            body: normalise(accessors.description),
            node: DeclSyntax(variable))
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
