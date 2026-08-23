actor Session {
    var hits = 7
    func summary() -> String { "old(hits=\(hits))" }
}

let session = Session()

func probe() async throws -> [String] { [await session.summary()] }
