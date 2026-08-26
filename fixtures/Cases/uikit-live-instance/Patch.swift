@testable import Fixture
import UIKit

extension Screen {
    @_dynamicReplacement(for: viewWillLayoutSubviews())
    func patched_viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        trace.append("viewWillLayoutSubviews=new")
    }

    @_dynamicReplacement(for: tapped())
    func patched_tapped() { trace.append("tapped=new") }
}

extension Box {
    @_dynamicReplacement(for: layoutSubviews())
    func patched_layoutSubviews() {
        super.layoutSubviews()
        trace.append("layoutSubviews=new")
    }

    @_dynamicReplacement(for: draw(_:))
    func patched_draw(_ rect: CGRect) { trace.append("draw=new") }
}
