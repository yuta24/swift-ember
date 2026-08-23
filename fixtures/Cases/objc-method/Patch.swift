@testable import Fixture
import Foundation

extension Bridged {
    @_dynamicReplacement(for: run())
    @objc func patched_run() -> String { "new" }
}
