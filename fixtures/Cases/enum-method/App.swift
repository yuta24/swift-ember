enum Kind {
    case a, b
    func name() -> String { "old(\(self))" }
}

let kind = Kind.b

func probe() async throws -> [String] { [kind.name()] }
