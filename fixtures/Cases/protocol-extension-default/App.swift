protocol Describable {
    func describe() -> String
}

extension Describable {
    func describe() -> String { "old" }
}

struct Thing: Describable {}

let thing = Thing()

func probe() async throws -> [String] { [thing.describe()] }
