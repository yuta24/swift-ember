@testable import Fixture

extension ViewModel {
    @_dynamicReplacement(for: render())
    func patched_render() -> String { "new(\(token))" }
}
