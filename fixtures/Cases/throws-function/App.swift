func risky() throws -> String { "old" }

func probe() async throws -> [String] { [try risky()] }
