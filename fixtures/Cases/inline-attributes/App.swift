@inline(__always)
func alwaysInline<T>(_ value: T) -> String { "old(\(value))" }

@inline(never)
func neverInline<T>(_ value: T) -> String { "old(\(value))" }

func probe() async throws -> [String] {
    ["always: \(alwaysInline(7))", "never: \(neverInline(7))"]
}
