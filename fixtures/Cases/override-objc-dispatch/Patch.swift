@testable import Fixture

// No @objc of its own: an override of an @objc method does not carry the
// attribute either, so this is what a generator copying the original emits.
extension MyController {
    @_dynamicReplacement(for: didLoad())
    func patched_didLoad() -> String { "new" }
}
