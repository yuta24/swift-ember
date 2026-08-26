@testable import Fixture
import SwiftUI

extension Row {
    @_dynamicReplacement(for: body)
    var patched_body: some View {
        // One Text becomes a VStack of two: the body's concrete type changes.
        VStack {
            Text("row \(tick)")
            Text("second line")
        }
    }
}
