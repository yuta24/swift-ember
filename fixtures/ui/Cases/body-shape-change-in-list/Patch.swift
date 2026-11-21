@testable import Fixture
import SwiftUI

extension Row {
    @_dynamicReplacement(for: body)
    var patched_body: some View {
        let row = "row \(tick)"
        let secondLine = "second line"
        // One Text becomes a VStack of two: the body's concrete type changes.
        return VStack {
            Text(row)
            Text(secondLine)
                .onAppear { UIHarness.render("\(secondLine)|\(row)") }
        }
    }
}
