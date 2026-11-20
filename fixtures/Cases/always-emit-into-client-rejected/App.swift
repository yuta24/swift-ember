@_alwaysEmitIntoClient
func emittedIntoClient() -> String { "old" }

func probe() async throws -> [String] { [emittedIntoClient()] }
