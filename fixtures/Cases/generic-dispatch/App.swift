@usableFromInline
protocol Scoring {
    func score() -> String
}

struct Box<T> {
    let value: T
}

extension Box where T: Equatable {
    func matches(_ other: T) -> String { "old(\(value == other))" }
}

extension Box: Scoring where T: Equatable {
    func score() -> String { "old(\(value == value))" }
}

func describe<T>(_ value: T) -> String { "old(\(value))" }

private func throughExistential(_ value: any Scoring) -> String { value.score() }

private func opaqueBox() -> some Scoring { Box(value: 7) }

// Serialize the unchanged caller so implicit dynamic leaves it alone.
// Keep the specialized call visible in SIL with @inline(never).
@inlinable
@inline(never)
func throughGeneric<P: Scoring>(_ value: P) -> String { value.score() }

private let concrete = Box(value: 7)
private let existential: any Scoring = concrete
private let opaque: some Scoring = opaqueBox()

private func capture<A>(_ function: @escaping (A) -> String, _ argument: A) -> () -> String {
    { function(argument) }
}

private let capturedMethod = concrete.score
private let capturedFunction = capture(describe, 7)

func probe() async throws -> [String] {
    [
        "constrained extension: \(concrete.matches(7))",
        "conditional witness, direct: \(concrete.score())",
        "conditional witness, existential: \(throughExistential(existential))",
        "conditional witness, opaque: \(opaque.score())",
        "conditional witness, generic: \(throughGeneric(concrete))",
        "captured method reference: \(capturedMethod())",
        "captured generic function reference: \(capturedFunction())",
    ]
}
