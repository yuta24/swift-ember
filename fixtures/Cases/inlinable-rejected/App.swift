// -enable-implicit-dynamic skips @inlinable, so no replacement key exists and
// the patch is rejected at compile time rather than loading and doing nothing.

@inlinable func helper() -> String { "old" }

func probe() async throws -> [String] { [helper()] }
