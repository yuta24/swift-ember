final class Sealed {
    final func run() -> String { "old" }
}

nonisolated(unsafe) let sealed = Sealed()

func probe() async throws -> [String] { [sealed.run()] }
