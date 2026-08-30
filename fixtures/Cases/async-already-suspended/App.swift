actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen: Bool

    init(open: Bool = false) {
        isOpen = open
    }

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isOpen = true
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}

func suspendedValue(gate: SuspensionGate) async -> String {
    await gate.wait()
    return "old-after-await"
}
