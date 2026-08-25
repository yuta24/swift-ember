// Storage cannot be replaced -- a copy would be different bytes -- but it can
// be read. This is the shape that decides reach in real code: most methods of
// most types touch private state.

struct Wallet {
    private var cents = 750
    private let symbol = "$"
    func label() -> String { "\(cents)" }
}

let wallet = Wallet()

func probe() async throws -> [String] { [wallet.label()] }
