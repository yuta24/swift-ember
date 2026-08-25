import Foundation
import SpliceCore
import SwiftSyntax

/// What one save turns into: declarations to replace in the running process,
/// and declarations the patch has to bring with it.
///
/// Nothing in the running binary can call a carried declaration: it did not
/// exist when that binary was linked. Carrying one changes no layout and
/// displaces nothing; it only gives the replaced bodies something to call.
public struct PatchPlan: Sendable {
    /// Bound to the original's replacement key by the Swift runtime.
    public let replacements: [PatchableDeclaration]
    /// Declarations the edit introduced, emitted into the patch under their own
    /// names so a replaced body can call them.
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
/// may differ, every surviving declaration must keep its signature, and a
/// declaration that disappeared is a rebuild. Anything else is a rebuild.
///
/// It used to be much longer. Reaching a `private` declaration meant carrying a
/// copy in the patch and replacing every caller, which needed a call-graph
/// closure and three guards around the ways a copy can be reached, or not
/// reached, by something the analysis could not see. Two reviews found ten
/// defects in that, every one of them a consequence of copying. Under
/// `-enable-private-imports` a private declaration has a replacement key like
/// any other and is simply replaced, and all of it went away. An over-conservative false negative costs a rebuild; a
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

        if let removed = beforeKeys.subtracting(afterKeys).sorted().first {
            return .rebuildRequired(reason: "the set of declarations changed: removed \(removed)")
        }

        // A declaration that appeared is carried rather than replaced: there is
        // no key to bind it to, and nothing that could already be calling it.
        var carried: [PatchableDeclaration] = []
        for identity in afterKeys.subtracting(beforeKeys).sorted() {
            if let unsupported = after.unsupported[identity] {
                return .rebuildRequired(reason: "\(identity) was added: \(unsupported.reason)")
            }
            guard let declaration = after.patchable[identity] else {
                return .rebuildRequired(reason: "\(identity) was added and this index does not model it")
            }
            guard declaration.carryable else {
                return .rebuildRequired(reason: "\(identity) was added; an override or an @objc member cannot be added by a patch, because an extension is not where it would have to go")
            }
            carried.append(declaration)
        }

        for (identity, old) in before.unsupported {
            guard let new = after.unsupported[identity] else {
                return .rebuildRequired(reason: "\(identity) changed kind")
            }
            if old.fingerprint != new.fingerprint {
                return .rebuildRequired(reason: "\(identity): \(new.reason)")
            }
        }

        var replacements: [PatchableDeclaration] = []
        for (identity, old) in before.patchable {
            guard let new = after.patchable[identity] else {
                return .rebuildRequired(reason: "\(identity) changed kind")
            }
            if old.signature != new.signature {
                return .rebuildRequired(reason: "\(identity): the signature changed, which is ABI-relevant")
            }
            if old.body != new.body { replacements.append(new) }
        }

        // A patch that replaces nothing would load and do nothing observable,
        // which FR-13 says must not be reported as a reload. Adding a helper
        // that nothing calls yet is exactly that, and it needs no patch: the
        // baseline does not advance, so the addition is still pending when the
        // edit that uses it arrives, and both land together.
        if replacements.isEmpty { return .noChange }

        return .hotPatch(PatchPlan(
            replacements: replacements.sorted { $0.identity < $1.identity },
            carried: carried.sorted { $0.identity < $1.identity }))
    }

    private static func identities(_ index: FileIndex) -> Set<String> {
        Set(index.patchable.keys).union(index.unsupported.keys)
    }
}

/// Emits the replacement source for one plan.
///
/// The original declaration node is reused as the template, with only its name
/// and attributes rewritten. Reassembling a signature from parts would lose
/// something eventually --- an ownership modifier, a global actor, a where
/// clause --- and the failure would be silent. Copying the node cannot.
public enum ReplacementGenerator {
    /// `privateImportOf` is the name of the source file being patched, and is
    /// passed only when that file declares something `private` or
    /// `fileprivate`.
    ///
    /// `@_private(sourceFile:)` is what lets the patch name a file-local
    /// declaration at all, and it requires the module to have been built with
    /// `-enable-private-imports`. Emitting it only where it is needed means a
    /// project that has not added that setting keeps working for every file
    /// without private code, rather than failing everywhere at once.
    public static func generate(module: String, generation: UInt64,
                                plan: PatchPlan, imports: [String] = [],
                                privateImportOf sourceFile: String? = nil) throws -> String {
        let moduleImport = sourceFile.map { "@_private(sourceFile: \"\($0)\") @testable import \(module)" }
            ?? "@testable import \(module)"
        var lines: [String] = [
            "// Generated by swift-splice for generation \(generation). Do not edit.",
            "",
            moduleImport,
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
            lines.append("// Carried into the patch: declarations that did not exist when the app")
            lines.append("// was built, so nothing already running can reach them.")
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

    /// A carried declaration keeps its own name, and its access level with it,
    /// so a replaced body calls it exactly as the edited source does.
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
