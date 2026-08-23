enum Registry {
    static func lookup() -> String { "old" }
}

func probe() async throws -> [String] { [Registry.lookup()] }
