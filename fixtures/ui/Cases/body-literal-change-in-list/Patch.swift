@testable import Fixture
import SwiftUI

extension Row {
    @_dynamicReplacement(for: body)
    var patched_body: some View {
        // Only the literal changes, so the body's concrete type is identical
        // and the storage cast finds what it recorded. This is the safe subset
        // DESIGN.md 13.1 names -- and the reason the refusal covers it anyway
        // is that nothing syntactic tells it apart from the case above.
        Text("patched \(tick)")
    }
}
