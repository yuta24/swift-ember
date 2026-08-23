@testable import Fixture

extension Box {
    @_dynamicReplacement(for: doubled)
    var patched_doubled: Int { raw * 100 }
}
