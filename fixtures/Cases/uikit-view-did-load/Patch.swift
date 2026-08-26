@testable import Fixture
import UIKit

extension Screen {
    @_dynamicReplacement(for: viewDidLoad())
    func patched_viewDidLoad() {
        super.viewDidLoad()
        trace.append("viewDidLoad=new")
        let label = UILabel()
        label.text = "new"
        view.addSubview(label)
    }
}
