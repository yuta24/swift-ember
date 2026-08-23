@testable import Fixture

extension Renderer {
    @_dynamicReplacement(for: body)
    var patched_body: some CustomStringConvertible { "new" }   // still String
}
