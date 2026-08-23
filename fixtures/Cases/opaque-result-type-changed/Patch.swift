@testable import Fixture

extension Renderer {
    @_dynamicReplacement(for: body)
    var patched_body: some CustomStringConvertible { 42 }   // String -> Int
}
