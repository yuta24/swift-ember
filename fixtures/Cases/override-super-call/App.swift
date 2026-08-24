// `super` is available inside an extension, so a replacement body can call it.
// Only `override` itself is illegal there, and the replacement does not need it.
// Without this an overridden method whose body starts with `super.viewDidLoad()`
// -- which is most of them -- would be out of reach even though the key exists.

import Foundation

class Screen: NSObject {
    @objc func setUp() -> String { "screen" }
}

final class DetailScreen: Screen {
    var trail: [String] = []
    override func setUp() -> String {
        let inherited = super.setUp()
        trail.append("old")
        return "\(inherited)+old"
    }
}

nonisolated(unsafe) let screen = DetailScreen()

func probe() async throws -> [String] {
    ["setUp=\(screen.setUp())", "trail=\(screen.trail.joined(separator: ","))"]
}
