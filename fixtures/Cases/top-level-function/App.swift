func subject() -> String { "old" }

func probe() async throws -> [String] { [subject()] }
