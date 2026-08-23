// The one case found so far that neither the compiler nor the loader rejects.
// The patch changes the concrete type behind `some`, compiles without a
// diagnostic, loads successfully, and then corrupts the program.
//
// The outcome is undefined rather than merely wrong. Whether it produces the
// new value, garbage, or SIGSEGV depends on whether the opaque type's metadata
// was already resolved before the patch loaded. `render()` below is read once
// per generation, so g0 resolves the metadata as String and g1 then reads an
// Int through it.
//
// This is the ordinary SwiftUI `var body: some View` shape, which is why
// opaque result types are rebuild-required rather than merely unsupported.

struct Renderer {
    var body: some CustomStringConvertible { "old" }
}

let renderer = Renderer()

func render() -> String { "\(renderer.body)" }

func probe() async throws -> [String] { [render()] }
