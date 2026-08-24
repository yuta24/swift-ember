@testable import Fixture
import SwiftUI

extension Holder {
    @_dynamicReplacement(for: maybe())
    func splice_maybe() -> (some View)? {
        VStack { Text("new"); Text("extra") }
    }
}
