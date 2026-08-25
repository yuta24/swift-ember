// A default argument compiles into a generator function of its own. A carried
// copy of `base` was invisible to it -- the generator kept calling the original
// and the edit reported success while changing nothing. A replacement is bound
// at the key, so the generator finds it like every other caller.

private func base() -> Int { 10 }

struct Cart {
    func total(_ n: Int = base()) -> Int { n }
    func run() -> Int { total() }
}

let cart = Cart()

func probe() async throws -> [String] { ["\(cart.run())"] }
