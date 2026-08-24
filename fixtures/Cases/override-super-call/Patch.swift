@testable import Fixture

extension DetailScreen {
    @_dynamicReplacement(for: setUp())
    func patched_setUp() -> String {
        let inherited = super.setUp()
        trail.append("new")
        return "\(inherited)+new"
    }
}
