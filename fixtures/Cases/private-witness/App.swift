// A private witness of a private protocol -- the one way a file-local
// declaration is reached without being named, through the witness table. A
// replacement is bound at the key the table points at, so the existential sees
// it too.

private protocol Rule {
    func check() -> String
}

private struct Always: Rule {
    func check() -> String { "old" }
}

private let rule: any Rule = Always()

func probe() async throws -> [String] { [rule.check()] }
