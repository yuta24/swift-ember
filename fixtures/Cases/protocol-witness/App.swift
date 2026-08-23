protocol Greeter {
    func greet() -> String
}

struct EnglishGreeter: Greeter {
    func greet() -> String { "old" }
}

let concrete = EnglishGreeter()
let existential: any Greeter = EnglishGreeter()

// Both dispatch paths are reported: a replacement that reached only the direct
// call would leave the existential line stale.
func probe() async throws -> [String] {
    ["direct=\(concrete.greet())", "existential=\(existential.greet())"]
}
