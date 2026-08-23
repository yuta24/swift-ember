// @_transparent is likewise skipped by implicit dynamic.

@_transparent func shortcut() -> String { "old" }

func probe() async throws -> [String] { [shortcut()] }
