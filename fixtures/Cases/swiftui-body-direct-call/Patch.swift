@testable import Fixture
import SwiftUI

extension Screen {
    @_dynamicReplacement(for: body)
    var ember_body: some View {
        evaluations.append("new")
        // A genuinely different tree shape: one Text becomes a stack of two.
        return VStack { Text("new"); Text("extra") }
    }
}
