@testable import Fixture
import Foundation

extension Plain {
    @_dynamicReplacement(for: plain())
    func patched_plain() -> String { "new" }
}

extension Counter {
    @_dynamicReplacement(for: objcMethod())
    func patched_objcMethod() -> String { "new" }

    @_dynamicReplacement(for: objcProperty)
    var patched_objcProperty: Int {
        get { storage + 1 }
        set { storage = newValue - 1 }
    }

    // Carried, not replacing: it exists only here. `@objcMembers` on the class
    // puts it in the same category as the three replacements above, with one
    // selector rather than two, and the count must stay 4.
    func carriedHelper() -> String { "carried" }
}
