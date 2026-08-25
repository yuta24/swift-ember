// A private type is nameable from the patch, so its members are ordinary
// replacement targets. Without private imports the patch cannot write
// `extension Helper` at all.

private struct Helper {
    func scale(_ v: Int) -> Int { v * 2 }
}

struct Cart {
    var cents = 100
    func total() -> String { "\(Helper().scale(cents))" }
}

let cart = Cart()

func probe() async throws -> [String] { [cart.total()] }
