@testable import Fixture
import SwiftUI
import EmberSwiftUI

extension Row {
    @_dynamicReplacement(for: body)
    var patched_body: some View {
        let __swift_ember_current_1_Row_body_inferred = VStack {
            Text("new \(tick)")
            Text("second line")
        }
        .background(RenderProbe(value: "new|\(stateID)"))
        .emberable()
        let __swift_ember_current_1_Row_body: SwiftUI.AnyView = __swift_ember_current_1_Row_body_inferred
        return __swift_ember_current_1_Row_body
    }
}
