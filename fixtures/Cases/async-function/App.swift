func load() async -> String { "old" }

func probe() async throws -> [String] { [await load()] }
