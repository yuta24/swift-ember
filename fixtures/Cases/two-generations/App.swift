struct Accumulator {
    var total = 0
    mutating func add() { total += 1 }
}

nonisolated(unsafe) var accumulator = Accumulator()

func probe() async throws -> [String] {
    accumulator.add()
    return ["total=\(accumulator.total)"]
}
