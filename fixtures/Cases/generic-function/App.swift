func describe<T: CustomStringConvertible>(_ value: T) -> String { "old(\(value))" }

func probe() async throws -> [String] { [describe(7)] }
