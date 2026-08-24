// The shape of UIViewController.viewDidLoad: the caller lives in another module
// and dispatches by selector rather than through Swift's vtable. An @objc member
// gets no native replacement key (see objc-method), and an override reached this
// way is replaced all the same.

import Foundation

class Controller: NSObject {
    @objc func didLoad() -> String { "base" }

    /// Stands in for the framework. Dispatching by selector is what makes this
    /// case different from override-method, where the call site is Swift.
    func invokedByFramework() -> String {
        (perform(#selector(didLoad))?.takeUnretainedValue() as? String) ?? "nil"
    }
}

final class MyController: Controller {
    override func didLoad() -> String { "old" }
}

nonisolated(unsafe) let controller = MyController()

func probe() async throws -> [String] {
    ["direct=\(controller.didLoad())", "selector=\(controller.invokedByFramework())"]
}
