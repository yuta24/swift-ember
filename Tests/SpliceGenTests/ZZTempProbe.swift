import Testing
import Foundation
@testable import SpliceGen

@Test func zzTempProbeGetSet() throws {
    let baseline = """
    import Foundation
    public class C {
        public var stored: Int = 0
        public var getSet: Int {
            get { stored + 2 }
            set { stored = newValue }
        }
    }
    """
    let current = baseline.replacingOccurrences(of: "stored + 2", with: "stored + 22")
    let c = ChangeClassifier.classify(baseline: baseline, current: current)
    guard case .hotPatch(let plan) = c else {
        Issue.record("not hotPatch: \(c)"); return
    }
    print("ZZPROBE replacements=\(plan.replacements.count) carried=\(plan.carried.count)")
    let src = try ReplacementGenerator.generate(module: "Fixture", generation: 1, plan: plan)
    print("ZZPROBE-SRC-BEGIN\n\(src)\nZZPROBE-SRC-END")
}
