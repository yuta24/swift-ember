// private declarations get no replacement key and are not visible to
// @testable import, so the patch cannot even name them.

private func secret() -> String { "old" }

func probe() async throws -> [String] { [secret()] }
