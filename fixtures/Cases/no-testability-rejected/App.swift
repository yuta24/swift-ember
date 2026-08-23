// Same subject as top-level-function, but the application is built without
// -enable-testing. The patch cannot import the module, and even if it could,
// the replacement keys would be hidden from the dynamic symbol table.

func subject() -> String { "old" }

func probe() async throws -> [String] { [subject()] }
