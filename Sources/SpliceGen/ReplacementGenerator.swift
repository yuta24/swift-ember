import Foundation
import SpliceCore
import SwiftSyntax

/// What one save turns into: declarations to replace in the running process,
/// and declarations the patch has to bring with it.
///
/// The second list is the one that is easy to misread. Nothing in the running
/// binary can call a carried declaration -- either it is `private`, and so
/// invisible to the patch module and to everything outside its file, or it is
/// new, and so did not exist when the binary was linked. Carrying one changes
/// no layout and displaces nothing; it only gives the replaced bodies something
/// to call.
public struct PatchPlan: Sendable {
    /// Bound to the original's replacement key by the Swift runtime.
    public let replacements: [PatchableDeclaration]
    /// Emitted into the patch under their own names. Swift resolves a reference
    /// from a replaced body to these rather than to the originals, which for a
    /// `private` declaration is the only copy the patch module can see at all.
    public let carried: [PatchableDeclaration]

    public init(replacements: [PatchableDeclaration], carried: [PatchableDeclaration]) {
        self.replacements = replacements
        self.carried = carried
    }
}

/// The verdict for one edited file, per DESIGN.md section 7.2.
public enum ChangeClassification: Sendable {
    case noChange
    case hotPatch(PatchPlan)
    case rebuildRequired(reason: String)
}

/// Compares two versions of a file and decides what, if anything, can be
/// applied to a running process.
///
/// The rule is deliberately narrow: nothing outside the indexed declarations
/// may differ, every surviving declaration must keep its signature, and every
/// consequence of an edit must land somewhere this tool can reach. Anything
/// else is a rebuild. An over-conservative false negative costs a rebuild; a
/// false positive corrupts a running process, so the asymmetry is the whole
/// design (PRD.md FR-4).
public enum ChangeClassifier {
    public static func classify(baseline: String, current: String,
                                policy: ClassifierPolicy = .default) -> ChangeClassification {
        classify(before: DeclarationIndexer.index(source: baseline, policy: policy),
                 after: DeclarationIndexer.index(source: current, policy: policy))
    }

    /// For callers that already have the indexes and need something else from
    /// them, such as the imports the generator has to copy. Parsing the file a
    /// second time to read those was both wasted work and a place for the two
    /// parses to disagree about the policy.
    public static func classify(before: FileIndex, after: FileIndex) -> ChangeClassification {

        if before.residue != after.residue {
            return .rebuildRequired(reason: "something outside a replaceable declaration changed, such as a type's declaration, an import, or a stored property")
        }

        let beforeKeys = identities(before)
        let afterKeys = identities(after)

        // Declarations the patch will emit under their own names, keyed by
        // identity so the two closures below can grow the set without emitting
        // anything twice.
        var carried: [String: PatchableDeclaration] = [:]
        var replacements: [String: PatchableDeclaration] = [:]

        // A declaration that disappeared is a rebuild, with one exception: a
        // file-local one that nothing in the file names any more. Its original
        // stays in the binary, unreferenced and unreachable, which is what
        // makes renaming a private helper -- a removal and an addition -- an
        // ordinary edit rather than a rebuild.
        let removedKeys = beforeKeys.subtracting(afterKeys)
        for identity in removedKeys.sorted() {
            guard let gone = before.local[identity] else {
                return .rebuildRequired(reason: "the set of declarations changed: removed \(identity)")
            }
            if mentioned(gone.simpleName, in: after) {
                return .rebuildRequired(reason: "\(identity) was removed but something still refers to \(gone.simpleName)")
            }
        }

        // A declaration that appeared is carried rather than replaced: there is
        // no key to bind it to, and nothing that could already be calling it.
        for identity in afterKeys.subtracting(beforeKeys).sorted() {
            if let unsupported = after.unsupported[identity] {
                return .rebuildRequired(reason: "\(identity) was added: \(unsupported.reason)")
            }
            guard let declaration = after.patchable[identity] ?? after.local[identity] else {
                return .rebuildRequired(reason: "\(identity) was added and this index does not model it")
            }
            guard declaration.carryable else {
                return .rebuildRequired(reason: "\(identity) was added; an override or an @objc member cannot be added by a patch, because an extension is not where it would have to go")
            }
            carried[identity] = declaration
        }

        for (identity, old) in before.unsupported {
            if removedKeys.contains(identity) { continue }
            guard let new = after.unsupported[identity] else {
                return .rebuildRequired(reason: "\(identity) changed kind")
            }
            if old.fingerprint != new.fingerprint {
                return .rebuildRequired(reason: "\(identity): \(new.reason)")
            }
        }

        for (identity, old) in before.patchable {
            if removedKeys.contains(identity) { continue }
            guard let new = after.patchable[identity] else {
                return .rebuildRequired(reason: "\(identity) changed kind")
            }
            if old.signature != new.signature {
                return .rebuildRequired(reason: "\(identity): the signature changed, which is ABI-relevant")
            }
            if old.body != new.body { replacements[identity] = new }
        }

        var changedLocal: [PatchableDeclaration] = []
        for (identity, old) in before.local {
            if removedKeys.contains(identity) { continue }
            guard let new = after.local[identity] else {
                return .rebuildRequired(reason: "\(identity) changed kind")
            }
            if old.signature != new.signature {
                return .rebuildRequired(reason: "\(identity): the signature changed, which is ABI-relevant")
            }
            if old.body != new.body {
                changedLocal.append(new)
                carried[identity] = new
            }
        }

        if replacements.isEmpty && carried.isEmpty { return .noChange }

        // Everything that calls a changed file-local declaration has to be
        // replaced or carried too, or the old copy stays live for those callers
        // and the same function means two things at once.
        var pending = changedLocal
        var closed: Set<String> = []
        while let declaration = pending.popLast() {
            let name = declaration.simpleName
            guard closed.insert(name).inserted else { continue }

            if after.residueMentions.contains(name) {
                return .rebuildRequired(reason: "\(name) changed, and it is used outside any declaration this tool can replace, such as an initialiser, a stored property's initial value, or a top-level statement")
            }
            for (identity, candidate) in after.unsupported where candidate.mentions.contains(name) {
                return .rebuildRequired(reason: "\(name) changed, and \(identity) uses it: \(candidate.reason)")
            }
            for (identity, candidate) in after.patchable
            where identity != declaration.identity && candidate.mentions.contains(name) {
                replacements[identity] = candidate
            }
            for (identity, candidate) in after.local
            where identity != declaration.identity && candidate.mentions.contains(name)
                && carried[identity] == nil {
                carried[identity] = candidate
                pending.append(candidate)
            }
        }

        // Every body the patch emits has to be able to name what it calls, and
        // a `private` declaration is not something `@testable import` can hand
        // it. Before this, editing any body that called a private helper
        // produced a patch that failed at COMPILE with "cannot find X in scope".
        var queue = Array(replacements.values) + Array(carried.values)
        while let declaration = queue.popLast() {
            for (identity, candidate) in after.local
            where identity != declaration.identity && carried[identity] == nil
                && declaration.mentions.contains(candidate.simpleName) {
                carried[identity] = candidate
                queue.append(candidate)
            }
        }

        // The guards below run here, on the finished sets, and not where they
        // were first written --- above the two closures. Up there they saw only
        // what the diff put in `carried` directly, and missed everything the
        // closures added, which is most of it.
        let carriedLocals = carried.values.filter { after.local[$0.identity] != nil }

        // A file-local declaration can also be reached through a witness table,
        // which is not a syntactic reference and so is invisible to the name
        // analysis. Swift only permits that when the protocol is itself
        // file-local (see `FileIndex.hasFileLocalProtocol`), so refusing that
        // whole file is enough and costs nothing anywhere else.
        if after.hasFileLocalProtocol && !carriedLocals.isEmpty {
            return .rebuildRequired(reason: "the file declares a private protocol, so a file-local declaration may be reached through a witness table rather than by name")
        }

        // A carried copy lives in an extension, where it is statically
        // dispatched. If the name is overridden anywhere in the file, a
        // replaced caller that used to reach the subclass's version through the
        // vtable would reach the copy instead --- measured as a process quietly
        // running the base class's implementation while the tool reported a
        // successful reload.
        for declaration in carriedLocals.sorted(by: { $0.identity < $1.identity })
        where after.overriddenNames.contains(declaration.simpleName) {
            return .rebuildRequired(reason: "\(declaration.simpleName) is overridden in this file, and a copy carried into an extension would not be")
        }

        // A body the patch emits may not name a file-local declaration there is
        // no way to carry: a stored property, a type, a typealias, an `@objc`
        // member. The patch would fail at COMPILE against generated source the
        // developer never wrote, blaming their file for it.
        // Sorted, both of them. Iterating the dictionaries and the mention set
        // in whatever order they came out meant two runs of the same input
        // blamed different names for the same refusal, which is not something a
        // developer should have to reproduce.
        if !after.uncarryableLocalNames.isEmpty {
            let emitted = (Array(replacements.values) + Array(carried.values))
                .sorted { $0.identity < $1.identity }
            for declaration in emitted {
                for name in declaration.mentions.sorted()
                where after.uncarryableLocalNames.contains(name) {
                    return .rebuildRequired(reason: "\(declaration.displayName) uses \(name), which is private and cannot be replaced or copied into a patch")
                }
            }
        }

        // A patch that replaces nothing would load and do nothing observable,
        // which FR-13 says must not be reported as a reload. Adding a helper
        // that nothing calls yet is exactly that, and it needs no patch: the
        // baseline does not advance, so the addition is still pending when the
        // edit that uses it arrives, and both land together.
        if replacements.isEmpty { return .noChange }

        return .hotPatch(PatchPlan(
            replacements: replacements.values.sorted { $0.identity < $1.identity },
            carried: carried.values.sorted { $0.identity < $1.identity }))
    }

    private static func identities(_ index: FileIndex) -> Set<String> {
        Set(index.patchable.keys).union(index.local.keys).union(index.unsupported.keys)
    }

    private static func mentioned(_ name: String, in index: FileIndex) -> Bool {
        if index.residueMentions.contains(name) { return true }
        if index.patchable.values.contains(where: { $0.mentions.contains(name) }) { return true }
        if index.local.values.contains(where: { $0.mentions.contains(name) }) { return true }
        return index.unsupported.values.contains { $0.mentions.contains(name) }
    }
}

/// Emits the replacement source for one plan.
///
/// The original declaration node is reused as the template, with only its name
/// and attributes rewritten. Reassembling a signature from parts would lose
/// something eventually --- an ownership modifier, a global actor, a where
/// clause --- and the failure would be silent. Copying the node cannot.
public enum ReplacementGenerator {
    public static func generate(module: String, generation: UInt64,
                                plan: PatchPlan, imports: [String] = []) throws -> String {
        var lines: [String] = [
            "// Generated by swift-splice for generation \(generation). Do not edit.",
            "",
            "@testable import \(module)",
        ]

        // The original file's imports, minus one that would duplicate the
        // module's own. Compared by module name: a `contains` test on the name
        // dropped `import FixtureKit` from a module called Fixture, and
        // `import CoreData` from one called Core, reintroducing the very
        // "cannot find type in scope" failure carrying imports exists to
        // prevent. Lines that are `#if` scaffolding pass through untouched.
        for statement in imports {
            guard statement.hasPrefix("import") || statement.contains(" import ") else {
                lines.append(statement)   // #if / #else / #endif
                continue
            }
            if DeclarationIndexer.moduleName(of: statement) == module { continue }
            lines.append(statement)
        }
        lines.append("")

        // Carried declarations first, so the file reads in the order the
        // compiler will need them and a human reading the patch sees what the
        // replacements below are calling.
        if !plan.carried.isEmpty {
            lines.append("// Carried into the patch: private declarations the patch module cannot")
            lines.append("// otherwise name, and declarations that did not exist when the app was")
            lines.append("// built. Nothing already running can reach these.")
            lines.append(contentsOf: try emit(plan.carried) { try copy($0) })
        }

        lines.append(contentsOf: try emit(plan.replacements) { try render($0, generation: generation) })

        return lines.joined(separator: "\n")
    }

    /// One extension per context keeps the output readable when several
    /// declarations on the same type change together.
    private static func emit(_ declarations: [PatchableDeclaration],
                             _ body: (PatchableDeclaration) throws -> String) rethrows -> [String] {
        var lines: [String] = []
        let grouped = Dictionary(grouping: declarations) { $0.contextPath ?? "" }

        for context in grouped.keys.sorted() {
            let members = grouped[context]!.sorted { $0.identity < $1.identity }
            let rendered = try members.map(body)

            if context.isEmpty {
                lines.append(contentsOf: rendered)
            } else {
                lines.append("extension \(context) {")
                lines.append(contentsOf: rendered.map { indent($0) })
                lines.append("}")
            }
            lines.append("")
        }
        return lines
    }

    private static func render(_ declaration: PatchableDeclaration, generation: UInt64) throws -> String {
        let newName = "splice_g\(generation)_" + sanitise(declaration.identity)
        let attribute = "@_dynamicReplacement(for: \(declaration.replacementTarget))"

        if var function = declaration.node.as(FunctionDeclSyntax.self) {
            function.name = .identifier(newName)
            function.attributes = strip(function.attributes)
            function.modifiers = strip(function.modifiers)
            return attribute + "\n" + function.trimmedDescription
        }

        if var variable = declaration.node.as(VariableDeclSyntax.self),
           let binding = variable.bindings.first {
            variable.bindings = PatternBindingListSyntax([
                binding.with(\.pattern, PatternSyntax(IdentifierPatternSyntax(identifier: .identifier(newName))))
            ])
            variable.attributes = strip(variable.attributes)
            variable.modifiers = strip(variable.modifiers)
            return attribute + "\n" + variable.trimmedDescription
        }

        throw SpliceError(stage: .generate, subject: declaration.identity,
                          reason: "this generator only emits functions and computed properties",
                          recovery: .rebuild)
    }

    /// A carried declaration keeps its own name, and its access level with it.
    ///
    /// Keeping the name is what makes the whole approach work without rewriting
    /// call sites: a replaced body that says `discount(cents)` resolves to the
    /// copy in the patch, because the original is `private` and the patch module
    /// cannot see it. Renaming would mean rewriting every reference, and getting
    /// that wrong where a local variable shadows the name would be silent.
    private static func copy(_ declaration: PatchableDeclaration) throws -> String {
        if var function = declaration.node.as(FunctionDeclSyntax.self) {
            function.modifiers = strip(function.modifiers)
            return function.trimmedDescription
        }
        if var variable = declaration.node.as(VariableDeclSyntax.self) {
            variable.modifiers = strip(variable.modifiers)
            return variable.trimmedDescription
        }
        throw SpliceError(stage: .generate, subject: declaration.identity,
                          reason: "this generator only emits functions and computed properties",
                          recovery: .rebuild)
    }

    /// `final` is implied inside an extension and illegal on a struct member,
    /// and `override` is illegal in an extension outright --- which is why the
    /// replacement is a separate declaration bound to the original's key rather
    /// than an override of its own. Everything else the original carried is
    /// load-bearing.
    private static func strip(_ modifiers: DeclModifierListSyntax) -> DeclModifierListSyntax {
        DeclModifierListSyntax(modifiers.filter { modifier in
            switch modifier.name.tokenKind {
            case .keyword(.final), .keyword(.override): false
            default: true
            }
        })
    }

    /// Drops any `@_dynamicReplacement` the source already carried, and takes
    /// the selector off an `@objc(name)`.
    ///
    /// The selector is the subtle one. Copied verbatim onto a replacement, it
    /// declares a second method with the *same* Objective-C selector as the
    /// original, and the patch fails to build: "method ... with Objective-C
    /// selector 'labelText' conflicts with method ...". A bare `@objc` binds
    /// through the replacement key exactly as well, and calls through the
    /// original custom selector still reach it --- measured.
    private static func strip(_ attributes: AttributeListSyntax) -> AttributeListSyntax {
        AttributeListSyntax(attributes.compactMap { element in
            guard case .attribute(var attribute) = element else { return element }
            switch attribute.attributeName.trimmedDescription {
            case "_dynamicReplacement":
                return nil
            case "objc":
                attribute.leftParen = nil
                attribute.arguments = nil
                // The space before `func` was the right paren's trailing
                // trivia, so removing the parens without putting it back
                // emitted `@objcfunc`.
                attribute.rightParen = nil
                return .attribute(attribute.with(\.trailingTrivia, .space))
            default:
                return element
            }
        })
    }

    private static func sanitise(_ identity: String) -> String {
        String(identity.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private static func indent(_ block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }
            .joined(separator: "\n")
    }
}
