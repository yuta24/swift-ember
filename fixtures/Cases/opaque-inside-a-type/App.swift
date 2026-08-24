// The SwiftUI exception covers a whole opaque return type, not an opaque
// position inside one. `View` carries a type eraser, so `some View` is already
// concrete -- but `(some View)?` is measured as `Optional<Text>`, unerased, and
// replacing it with a different tree is the undefined behaviour that
// Cases/opaque-result-type-changed documents.
//
// This case exists because the classifier once decided the safe case by asking
// whether the return type mentioned "View", which would have told a developer
// this edit was harmless and then handed them a crash.

import SwiftUI

struct Holder {
    var whole: some View { Text("old") }
    func maybe() -> (some View)? { Text("old") }
}

nonisolated(unsafe) let holder = Holder()

func probe() async throws -> [String] {
    let whole = await MainActor.run { holder.whole }
    let maybe = await MainActor.run { holder.maybe() }
    return ["whole=\(type(of: whole))", "maybe=\(type(of: maybe))"]
}
