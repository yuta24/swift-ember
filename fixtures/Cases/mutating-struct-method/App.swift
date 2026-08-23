struct Accumulator {
    var total = 0
    mutating func add() { total += 1 }
}

nonisolated(unsafe) var accumulator = Accumulator()

// Each probe mutates the same value, so the running total shows both that the
// replacement took effect and that the pre-patch state survived.
func probe() async throws -> [String] {
    accumulator.add()
    return ["total=\(accumulator.total)"]
}
