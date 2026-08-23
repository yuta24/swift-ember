class Counter {
    var value = 0
    func label() -> String { "old" }
}

nonisolated(unsafe) let counter: Counter = {
    let c = Counter()
    c.value = 42
    return c
}()

func probe() async throws -> [String] { [counter.label(), "value=\(counter.value)"] }
