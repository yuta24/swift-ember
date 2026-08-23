struct Price {
    var value: Int
    func formatted() -> String { "old(\(value))" }
}

let price = Price(value: 10)

func probe() async throws -> [String] { [price.formatted()] }
