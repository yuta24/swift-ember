// Without -enable-private-imports the module cannot be imported privately, and
// the patch is rejected at COMPILE before anything reaches the process. This is
// what a project that has not added the build setting will see, so the daemon
// translates this exact diagnostic into the setting it is missing.

private func secret() -> String { "old" }

func probe() async throws -> [String] { [secret()] }
