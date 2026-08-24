// An override gets a replacement key of its own, and the replacement goes in an
// extension like any other. That is legal because the replacement is not itself
// an override -- it is a separate declaration bound to the original's key -- and
// only `override` is forbidden in an extension.
//
// Both dispatch paths are reported: a replacement reached only through the
// static type would leave the polymorphic line stale.

class Formatter {
    func format(_ value: Int) -> String { "base(\(value))" }
}

final class CurrencyFormatter: Formatter {
    var calls = 0
    override func format(_ value: Int) -> String {
        calls += 1
        return "old(\(value))"
    }
}

nonisolated(unsafe) let formatter = CurrencyFormatter()

func probe() async throws -> [String] {
    let direct = formatter.format(1)
    let polymorphic = (formatter as Formatter).format(2)
    return ["direct=\(direct)", "polymorphic=\(polymorphic)", "calls=\(formatter.calls)"]
}
