@testable import Fixture
import SwiftUI
import SpliceSwiftUI

extension Row {
    @_dynamicReplacement(for: body)
    var patched_body: some View {
        let __swift_splice_current_1_Row_body: SwiftUI.AnyView = VStack {
            Text("new \(tick)")
            Text("second line")
        }
        .background(RenderProbe(value: "new|\(stateID)"))
        .enableSplice()
        return __swift_splice_current_1_Row_body
    }
}
