func fetch() async throws -> String { "old" }

func probe() async throws -> [String] { [try await fetch()] }
