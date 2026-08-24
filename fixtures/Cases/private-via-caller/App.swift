// A private function cannot be replaced (see private-rejected): it gets no
// replacement key and @testable import cannot name it. Its new implementation
// still reaches the process if the patch carries a copy and replaces every
// caller -- and the callers are all in this file, because private is
// file-scoped.
//
// `receipt()` is deliberately left unreplaced. It calls `total()`, which is
// replaced, so it observes the new behaviour without being touched: the
// closure that has to be replaced is the callers of the private function, not
// everything downstream of it.

private func discount(_ cents: Int) -> Int { cents }

struct Order {
    var cents = 1000
    func total() -> String { "\(discount(cents))" }
    func receipt() -> String { "receipt: \(total())" }
}

let order = Order()

func probe() async throws -> [String] { [order.receipt(), "total=\(order.total())"] }
