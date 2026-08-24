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
    /// The declared name with nothing around it, which is how a reference to
    /// this declaration is spelled elsewhere in the file.
    public let simpleName: String
    /// Every identifier this declaration mentions, signature and body alike.
    ///
    /// Deliberately an over-approximation: a local variable that happens to
    /// share a name with a declaration counts as a mention. That widens the
    /// set of declarations a patch has to carry or replace, which costs a
    /// larger patch or a rebuild. Missing a mention would instead leave a live
    /// call bound to the old code, so the error has to lean this way.
    public let mentions: Set<String>
    /// Whether a copy of this declaration can be emitted into a patch.
    ///
    /// False for an `override`, which an extension cannot declare, and for an
    /// `@objc` member, whose callers reach it through the Objective-C runtime
    /// and would keep finding the original however many copies exist.
    public let carryable: Bool
}

/// A declaration that exists but is out of scope, recorded so a change to it
/// produces a specific reason rather than a generic rejection.
public struct UnsupportedDeclaration: Sendable {
    public let identity: String
    public let reason: String
    public let fingerprint: String
    /// As on `PatchableDeclaration`, and needed for the same question: if a
    /// file-local declaration changes, is anything that cannot be patched
    /// still calling it?
    public let mentions: Set<String>
}

public struct FileIndex: Sendable {
    /// Declarations that can be replaced in the running process.
    public let patchable: [String: PatchableDeclaration]
    /// `private` and `fileprivate` declarations. These get no replacement key
    /// and `@testable import` cannot name them, so they can never be replaced
    /// --- but a patch can carry its own copy, and Swift resolves a reference
    /// from a patched body to that copy, because the original is invisible to
    /// the patch module. Measured in `fixtures/Cases/private-via-caller`.
    public let local: [String: PatchableDeclaration]
    public let unsupported: [String: UnsupportedDeclaration]
    /// The file's imports, verbatim and in order. A patch is compiled on its
    /// own, so a body that mentions `VStack` needs the `import SwiftUI` its
    /// original file had; without them the patch fails at COMPILE with
    /// "cannot find type in scope", which reads like the tool's bug.
    public let imports: [String]
    /// Everything else in the file, hashed, so that a change nobody indexed
    /// still forces a rebuild instead of passing unnoticed.
    public let residue: String
    /// Identifiers mentioned by everything in the residue: initialisers,
    /// `init`, `subscript`, top-level statements, type heads.
    ///
    /// A file-local declaration named here is called from somewhere no patch
    /// can reach, so carrying a new copy of it would leave that call running
    /// the old one. The whole file has to be rebuilt instead.
    public let residueMentions: Set<String>
    /// Simple names of declarations in this file that carry `override`.
    ///
    /// A carried copy of a class member sits in an extension, where it is
    /// statically dispatched and can never be overridden. If anything in the
    /// file overrides that name, replacing a caller with one that calls the
    /// copy silently stops the subclass's version from running. `private` and
    /// `fileprivate` members can only be overridden from inside their own
    /// file, so this file-scoped list is complete for the declarations it
    /// guards.
    public let overriddenNames: Set<String>
    /// Names declared `private` or `fileprivate` here that no patch can carry:
    /// stored properties, types, typealiases, `override`s, `@objc` members.
    ///
    /// A patch that names one of these cannot compile --- `@testable import`
    /// does not reach a file-local declaration, and there is no copy to reach
    /// instead. Refusing while the reason is still legible beats emitting a
    /// patch that fails at COMPILE against generated source the developer did
    /// not write.
    public let uncarryableLocalNames: Set<String>
    /// A `private` or `fileprivate` protocol anywhere in the file.
    ///
    /// The one way a file-local declaration can be reached other than by being
    /// named: a witness table entry, which is not a syntactic reference and so
    /// is invisible to the analysis above. Swift refuses a `private` witness
    /// for an `internal` protocol ("must be declared internal because it
    /// matches a requirement"), so this can only arise when the protocol is
    /// itself file-local. Rare enough to answer by refusing the whole route.
    public let hasFileLocalProtocol: Bool
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
    var local: [String: PatchableDeclaration] = [:]
    var unsupported: [String: UnsupportedDeclaration] = [:]
    var residue: [String] = []
    var residueMentions: Set<String> = []
    var uncarryableLocalNames: Set<String> = []

    /// Records a declaration this index will replace or carry.
    ///
    /// Two declarations that reduce to the same identity cannot be told apart,
    /// so neither is usable. Both are demoted, and the fingerprint carries each
    /// of them, so a change to either still forces a rebuild.
    mutating func add(_ declaration: PatchableDeclaration, fingerprint: String, fileLocal: Bool) {
        let identity = declaration.identity
        if let existing = displace(identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing + "|" + fingerprint,
                mentions: (unsupported[identity]?.mentions ?? []).union(declaration.mentions))
            return
        }
        if fileLocal {
            local[identity] = declaration
        } else {
            patchable[identity] = declaration
        }
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
    mutating func reject(_ identity: String, _ reason: String, _ fingerprint: String,
                         mentions: Set<String>) {
        residue.append("unsupported:" + identity)
        if let existing = displace(identity) {
            unsupported[identity] = UnsupportedDeclaration(
                identity: identity, reason: duplicateReason(identity),
                fingerprint: existing + "|" + fingerprint,
                mentions: (unsupported[identity]?.mentions ?? []).union(mentions))
            return
        }
        unsupported[identity] = UnsupportedDeclaration(
            identity: identity, reason: reason, fingerprint: fingerprint, mentions: mentions)
    }

    /// Anything already filed under this identity, removed and returned as its
    /// fingerprint, or nil if the identity is new.
    private mutating func displace(_ identity: String) -> String? {
        if let existing = unsupported.removeValue(forKey: identity) { return existing.fingerprint }
        if let existing = patchable.removeValue(forKey: identity) { return existing.signature + existing.body }
        if let existing = local.removeValue(forKey: identity) { return existing.signature + existing.body }
        return nil
    }

    mutating func note(_ text: String, mentions: Set<String>) {
        residue.append(text)
        residueMentions.formUnion(mentions)
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

        // Collected over the whole tree, separately from the walk below.
        //
        // The walk stops in three places -- a file-local type, an `#if` block,
        // a function body -- and summarises what is inside as residue. That is
        // right for deciding what changed, and wrong for these facts: an
        // `override` inside `#if os(iOS)` is still an override, and a guard
        // that never saw it let a carried copy silently displace it. Measured,
        // with the guard in place, as a process running the base class's
        // implementation while the reload was reported as successful.
        let facts = FileFacts(of: file)

        let imports = collectImports(file.statements.map(\.item))
        let importsSwiftUI = imports.contains { moduleName(of: $0) == "SwiftUI" }

        walk(members: file.statements.map(\.item), context: [], policy: policy,
             importsSwiftUI: importsSwiftUI, into: &builder)

        // Not sorted: order is part of the fingerprint. Sorting made a pure
        // reordering of declarations -- enum cases, say -- invisible.
        // Anything declared file-local that did not end up carryable is a name
        // no patch can write down. Derived by subtraction rather than by
        // listing the ways a declaration can fail to be carryable, because
        // that list is exactly the part that kept turning out to be
        // incomplete: an opaque return type, an operator, a comma-separated
        // binding, two declarations colliding on one identity. Each of those
        // rejections happens somewhere else, and each one had forgotten to say
        // so here.
        let carriedNames = Set(builder.local.values.map(\.simpleName))
        let uncarryable = builder.uncarryableLocalNames
            .union(facts.fileLocalNames.subtracting(carriedNames))

        return FileIndex(patchable: builder.patchable, local: builder.local,
                         unsupported: builder.unsupported, imports: imports,
                         residue: builder.residue.joined(separator: "\n"),
                         residueMentions: builder.residueMentions,
                         overriddenNames: facts.overriddenNames,
                         uncarryableLocalNames: uncarryable,
                         hasFileLocalProtocol: facts.hasFileLocalProtocol)
    }

    private static func walk(members: [CodeBlockItemSyntax.Item], context: [String],
                             policy: ClassifierPolicy, importsSwiftUI: Bool,
                             fileLocal: Bool = false, contextNames: Set<String> = [],
                             into builder: inout IndexBuilder) {
        for item in members {
            guard case .decl(let decl) = item else {
                builder.note(normalise(item), mentions: identifiers(in: item))
                continue
            }
            visit(decl, context: context, policy: policy, importsSwiftUI: importsSwiftUI,
                  fileLocal: fileLocal, contextNames: contextNames, into: &builder)
        }
    }

    /// `fileLocal` is inherited, not just read off the declaration. A member of
    /// a `private extension` is file-local without saying so, and reading only
    /// its own modifiers filed it as patchable --- claiming a replacement key
    /// that does not exist, and a `@testable` visibility it does not have.
    private static func visit(_ decl: DeclSyntax, context: [String],
                              policy: ClassifierPolicy, importsSwiftUI: Bool,
                              fileLocal: Bool, contextNames: Set<String>,
                              into builder: inout IndexBuilder) {
        // Before the branch below, not after: ProtocolDeclSyntax conforms to
        // both DeclGroupSyntax and NamedDeclSyntax, so it would otherwise be
        // walked as if it were a concrete type and its requirements mistaken
        // for implementations.
        if let proto = decl.as(ProtocolDeclSyntax.self) {
            // Requirements have no bodies worth replacing, and changing one
            // changes the witness table. Default implementations live in
            // extensions and are handled there.
            builder.note(normalise(proto), mentions: identifiers(in: Syntax(proto)))
            return
        }

        if let type = decl.asProtocol(NamedDeclSyntax.self) as? (any DeclGroupSyntax & NamedDeclSyntax) {
            // class / struct / enum / actor: recurse, and fingerprint the
            // declaration head so that changing inheritance or generics is seen.
            let name = type.name.text

            // A file-local *type* is where the carry route ends. Its members
            // could be copied, but the extension they would have to be copied
            // into names a type the patch module cannot see. So the whole
            // declaration becomes residue --- any edit inside it is a rebuild
            // --- and the name is recorded, so a body elsewhere that mentions
            // it is refused with a reason rather than compiled into a patch
            // that cannot find the type.
            if fileLocal || isFileLocal(type.modifiers) {
                builder.uncarryableLocalNames.insert(name)
                builder.note(normalise(type), mentions: identifiers(in: Syntax(type)))
                return
            }

            let head = head(of: type)
            builder.note(normalise(head), mentions: identifiers(in: Syntax(head)))
            walk(members: type.memberBlock.members.map { .decl($0.decl) },
                 context: context + [name], policy: policy, importsSwiftUI: importsSwiftUI,
                 contextNames: contextNames.union([name]), into: &builder)
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
            builder.note(normalise(head), mentions: identifiers(in: Syntax(head)))
            // The extended type's name goes into every member's mentions. The
            // patch writes `extension Helper {` around them, so a member of an
            // extension of a *private* type names that type as surely as if
            // its body did --- and `extension Helper` carries no `private` of
            // its own to notice.
            walk(members: ext.memberBlock.members.map { .decl($0.decl) },
                 context: [name], policy: policy, importsSwiftUI: importsSwiftUI,
                 fileLocal: fileLocal || isFileLocal(ext.modifiers),
                 contextNames: contextNames.union(identifiers(in: Syntax(ext.extendedType))),
                 into: &builder)
            return
        }

        if let function = decl.as(FunctionDeclSyntax.self) {
            record(function: function, context: context, policy: policy,
                   importsSwiftUI: importsSwiftUI, fileLocal: fileLocal,
                   contextNames: contextNames, into: &builder)
            return
        }

        if let variable = decl.as(VariableDeclSyntax.self) {
            record(variable: variable, context: context, policy: policy,
                   importsSwiftUI: importsSwiftUI, fileLocal: fileLocal,
                   contextNames: contextNames, into: &builder)
            return
        }

        // Not modelled. If it is file-local it is also unreachable from a
        // patch, and a typealias or an operator declaration is named by the
        // bodies that use it, so record the name for the same reason as above.
        if fileLocal || isFileLocal(modifiers(of: decl)),
           let named = decl.asProtocol(NamedDeclSyntax.self) {
            builder.uncarryableLocalNames.insert(named.name.text)
        }
        builder.note(normalise(decl), mentions: identifiers(in: Syntax(decl)))
    }

    /// The modifiers of any declaration this index does not model specifically.
    private static func modifiers(of decl: DeclSyntax) -> DeclModifierListSyntax {
        decl.asProtocol(WithModifiersSyntax.self)?.modifiers ?? DeclModifierListSyntax([])
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
                               fileLocal inherited: Bool, contextNames: Set<String>,
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
        let mentions = identifiers(in: Syntax(function)).union(contextNames)
        let fileLocal = inherited || isFileLocal(function.modifiers)

        // A default argument is compiled into a generator function of its own,
        // which no patch replaces: `@_dynamicReplacement` replaces the function,
        // not the code that computes its defaults. So a name reached only from
        // there is reached from somewhere unpatchable, exactly like an
        // initialiser. Without this, changing a private helper called in a
        // default argument reported a successful reload and changed nothing.
        for parameter in function.signature.parameterClause.parameters {
            guard let value = parameter.defaultValue else { continue }
            builder.residueMentions.formUnion(identifiers(in: Syntax(value)))
        }

        var withoutBody = function.detached
        withoutBody.body = nil
        let signature = normalise(withoutBody)

        guard let body = function.body else {
            builder.reject(identity, "declaration has no body", signature, mentions: mentions)
            return
        }

        let fingerprint = signature + normalise(body)

        if let reason = rejection(attributes: function.attributes, modifiers: function.modifiers) {
            builder.reject(identity, reason, fingerprint, mentions: mentions)
            return
        }

        if isOperator(function.name) {
            // Operators do get replacement keys (Appendix A), but the spelling
            // of the @_dynamicReplacement(for:) target for one is not something
            // this generator knows, and guessing would produce a patch that
            // either fails to compile or replaces the wrong thing.
            builder.reject(identity, "operator declarations are not supported by this generator",
                           fingerprint, mentions: mentions)
            return
        }

        let returnType = function.signature.returnClause?.type
        if containsOpaqueType(returnType) {
            let erasedView = isErasedSwiftUIView(returnType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                builder.reject(identity, erasedView ? swiftUIBodyReason : opaqueReason,
                               fingerprint, mentions: mentions)
                return
            }
        }

        let carryable = isCarryable(attributes: function.attributes, modifiers: function.modifiers)

        // A file-local declaration that cannot be copied cannot be reached at
        // all: it has no replacement key either. Say which of the two it is.
        if fileLocal && !carryable {
            builder.uncarryableLocalNames.insert(function.name.text)
            builder.reject(identity, fileLocalUncarryableReason, fingerprint, mentions: mentions)
            return
        }

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
            mentions: mentions,
            carryable: carryable),
            fingerprint: fingerprint, fileLocal: fileLocal)
    }

    // MARK: - Properties

    private static func record(variable: VariableDeclSyntax, context: [String],
                               policy: ClassifierPolicy, importsSwiftUI: Bool,
                               fileLocal inherited: Bool, contextNames: Set<String>,
                               into builder: inout IndexBuilder) {
        let mentions = identifiers(in: Syntax(variable)).union(contextNames)
        let fileLocal = inherited || isFileLocal(variable.modifiers)


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
            builder.note(normalise(variable), mentions: mentions)
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
            if fileLocal { builder.uncarryableLocalNames.insert(name) }
            builder.reject(identity, "stored property; changing one changes the type's layout",
                           normalise(variable), mentions: mentions)
            return
        }

        var withoutBody = variable.detached
        withoutBody.bindings = PatternBindingListSyntax([binding.detached.with(\.accessorBlock, nil)])
        let signature = normalise(withoutBody)
        let fingerprint = signature + normalise(accessors)

        if let reason = rejection(attributes: variable.attributes, modifiers: variable.modifiers) {
            builder.reject(identity, reason, fingerprint, mentions: mentions)
            return
        }

        let declaredType = binding.typeAnnotation?.type
        if containsOpaqueType(declaredType) {
            let erasedView = isErasedSwiftUIView(declaredType, importsSwiftUI: importsSwiftUI)
            if !(erasedView && policy.allowOpaqueResultTypes) {
                builder.reject(identity, erasedView ? swiftUIBodyReason : opaqueReason,
                               fingerprint, mentions: mentions)
                return
            }
        }

        let carryable = isCarryable(attributes: variable.attributes, modifiers: variable.modifiers)
        if fileLocal && !carryable {
            builder.uncarryableLocalNames.insert(name)
            builder.reject(identity, fileLocalUncarryableReason, fingerprint, mentions: mentions)
            return
        }

        builder.add(PatchableDeclaration(
            identity: identity,
            contextPath: context.isEmpty ? nil : context.joined(separator: "."),
            replacementTarget: name,
            signature: signature,
            body: normalise(accessors),
            node: DeclSyntax(variable),
            displayName: identity,
            simpleName: name,
            mentions: mentions,
            carryable: carryable),
            fingerprint: fingerprint, fileLocal: fileLocal)
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

    static let fileLocalUncarryableReason = """
        is private or fileprivate, so it has no replacement key, and it is an \
        override or an @objc member, so a patch cannot carry a copy either
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

    /// Every identifier token in a node.
    static func identifiers(in node: Syntax) -> Set<String> {
        let collector = IdentifierCollector(viewMode: .sourceAccurate)
        collector.walk(node)
        return collector.names
    }

    static func identifiers(in item: CodeBlockItemSyntax.Item) -> Set<String> {
        switch item {
        case .decl(let decl): identifiers(in: Syntax(decl))
        case .stmt(let stmt): identifiers(in: Syntax(stmt))
        case .expr(let expr): identifiers(in: Syntax(expr))
        }
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

private final class IdentifierCollector: SyntaxVisitor {
    var names: Set<String> = []

    /// Operators count as names here.
    ///
    /// A call to `<+>` spells it with an operator token, so collecting only
    /// identifiers left a private operator's call sites invisible to every
    /// guard. Measured: the patch compiled, the private overload was not in
    /// it, and the call silently rebound to a generic one.
    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        switch node.tokenKind {
        case .identifier(let text),
             .binaryOperator(let text),
             .prefixOperator(let text),
             .postfixOperator(let text):
            names.insert(text)
        default:
            break
        }
        return .skipChildren
    }
}

/// Facts about a file that the indexing walk is not in a position to collect,
/// because it deliberately stops descending in places these still reach.
///
/// Every one of these is read by a guard that refuses an edit. A fact this
/// misses is a refusal that does not happen.
struct FileFacts {
    /// Simple names of declarations carrying `override`, wherever they are.
    let overriddenNames: Set<String>
    /// Simple names of every `private` or `fileprivate` declaration, whatever
    /// kind it is. The index narrows this to the ones it could not carry.
    let fileLocalNames: Set<String>
    /// Whether a file-local protocol exists, which is the one way a file-local
    /// declaration can be reached without being named.
    let hasFileLocalProtocol: Bool

    init(of file: SourceFileSyntax) {
        let collector = FactsCollector(viewMode: .sourceAccurate)
        collector.walk(file)
        overriddenNames = collector.overriddenNames
        fileLocalNames = collector.fileLocalNames
        hasFileLocalProtocol = collector.hasFileLocalProtocol
    }
}

private final class FactsCollector: SyntaxVisitor {
    var overriddenNames: Set<String> = []
    var fileLocalNames: Set<String> = []
    var hasFileLocalProtocol = false

    private func record(name: String, _ modifiers: DeclModifierListSyntax) {
        if DeclarationIndexer.isOverride(modifiers) { overriddenNames.insert(name) }
        if DeclarationIndexer.isFileLocal(modifiers) { fileLocalNames.insert(name) }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // `node.name` is an operator token for `func <+>`, and its text is how
        // a call site spells it, which is what the guards compare against.
        record(name: node.name.text, node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            record(name: name, node.modifiers)
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if DeclarationIndexer.isOverride(node.modifiers) { overriddenNames.insert("subscript") }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if DeclarationIndexer.isFileLocal(node.modifiers) { hasFileLocalProtocol = true }
        record(name: node.name.text, node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.modifiers); return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.modifiers); return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.modifiers); return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.modifiers); return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.modifiers); return .visitChildren
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
