// Two patches in a row, each carrying its own copy of the same private
// declaration.
//
// The question is whether the copies collide: both are named `rate`, both are
// private, and both are loaded into the same process. They do not, because each
// patch is its own module, and the newest replacement of the caller wins --- so
// the copy that is reached is the one belonging to the patch that won.

private func rate() -> Int { 1 }

struct Meter {
    var ticks = 100
    func reading() -> String { "\(ticks * rate())" }
}

let meter = Meter()

func probe() async throws -> [String] { [meter.reading()] }
