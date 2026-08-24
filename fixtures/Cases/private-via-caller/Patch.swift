@testable import Fixture

// The private function's new implementation, under a name of its own. The
// original stays in the binary, unreplaced and now unreachable from any
// declaration this patch rewrote.
private func splice_discount(_ cents: Int) -> Int { cents - 100 }

extension Order {
    // The only caller of `discount` in the file. Replacing some callers and not
    // others would leave two versions live at once, so this set is all of them
    // or the change is not applied at all.
    @_dynamicReplacement(for: total())
    func patched_total() -> String { "\(splice_discount(cents))" }
}
