// Replacing an opaque result type is safe only while the underlying concrete
// type is unchanged. The opposite case is covered by
// Cases/opaque-result-type-changed.

struct Renderer {
    var body: some CustomStringConvertible { "old" }
}

let renderer = Renderer()

func probe() async throws -> [String] { ["\(renderer.body)"] }
