// A declaration carried in the patch and in no other image.
//
// Nothing in the running binary can call it -- it did not exist when that
// binary was linked -- so adding one changes no layout and breaks no caller.
// A replaced body can call it, which is what "add a helper and keep going"
// would rest on.

struct Cart {
    var items = [100, 200]
    func label() -> String { "\(items.reduce(0, +)) cents" }
}

let cart = Cart()

func probe() async throws -> [String] { [cart.label()] }
