// An @objc member dispatches through the Objective-C runtime and gets no
// native replacement key, yet dynamic replacement still applies to it.
// Absence of a key is therefore not proof that a declaration is unpatchable.

import Foundation

final class Bridged: NSObject {
    @objc func run() -> String { "old" }
}

nonisolated(unsafe) let bridged = Bridged()

func probe() async throws -> [String] { [bridged.run()] }
