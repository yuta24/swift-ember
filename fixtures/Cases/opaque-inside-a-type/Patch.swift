@testable import Fixture
import SwiftUI

extension Holder {
    @_dynamicReplacement(for: maybe())
    func ember_maybe() -> (some View)? {
        VStack { Text("new"); Text("extra") }
    }
}
