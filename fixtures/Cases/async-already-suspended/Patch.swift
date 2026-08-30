@testable import Fixture

@_dynamicReplacement(for: suspendedValue(gate:))
func patchedSuspendedValue(gate: SuspensionGate) async -> String {
    await gate.wait()
    return "new-after-await"
}
