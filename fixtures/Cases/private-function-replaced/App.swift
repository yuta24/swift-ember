// With `-enable-private-imports` a private declaration has a replacement key
// like any other, so it is replaced rather than copied.
//
// `total()` is deliberately left alone. It sees the new `discount` all the
// same, which a carried copy could never arrange: a copy is only reached by
// the bodies the patch rewrote.

private func discount(_ cents: Int) -> Int { cents }

struct Order {
    var cents = 1000
    func total() -> String { "\(discount(cents))" }
}

let order = Order()

func probe() async throws -> [String] { [order.total()] }
