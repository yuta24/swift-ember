import Testing

/// The process-level proof for atomic multi-file generation. Coordinator
/// tests pin the commit boundary; these pin that the one image it commits can
/// actually resolve cross-file additions and distinct private scopes.

@Test func anAddedHelperInAnotherFileLandsWithItsCaller() {
    let baselines = [
        """
        func subject() -> String { "old" }
        \(probe("[subject()]"))
        """,
        "func existing() -> String { \"existing\" }",
    ]
    let currents = [
        baselines[0].replacingOccurrences(of: #"{ "old" }"#,
                                           with: "{ helper() }"),
        baselines[1] + "\nfunc helper() -> String { \"new\" }\n",
    ]

    do {
        let outcome = try Loop.runAtomic(baselines: baselines, currents: currents)
        #expect(outcome.before == ["g0: old"])
        #expect(outcome.after.suffix(1) == ["g1: new"])
    } catch {
        Issue.record("\(error)")
    }
}

@Test func privateDeclarationsFromTwoFilesRemainDistinct() {
    let baselines = [
        """
        private func helper() -> String { "old-a" }
        func callA() -> String { helper() }
        """,
        """
        private func helper() -> String { "old-b" }
        func callB() -> String { helper() }
        \(probe("[callA(), callB()]"))
        """,
    ]
    let currents = [
        baselines[0].replacingOccurrences(of: "old-a", with: "new-a"),
        baselines[1].replacingOccurrences(of: "old-b", with: "new-b"),
    ]

    do {
        let outcome = try Loop.runAtomic(baselines: baselines, currents: currents)
        #expect(outcome.before == ["g0: old-a", "g0: old-b"])
        #expect(outcome.after.suffix(2) == ["g1: new-a", "g1: new-b"])
    } catch {
        Issue.record("\(error)")
    }
}

@Test func editingACarriedHelperInAnotherFileReachesItsCaller() {
    let baseline = [
        """
        func subject() -> String { "old" }
        \(probe("[subject()]"))
        """,
        "func existing() -> String { \"existing\" }",
    ]
    let first = [
        baseline[0].replacingOccurrences(of: #"{ "old" }"#,
                                          with: "{ helper() }"),
        baseline[1] + "\nfunc helper() -> String { \"first\" }\n",
    ]
    let second = [
        first[0],
        first[1].replacingOccurrences(of: "first", with: "second"),
    ]

    do {
        let output = try Loop.runAtomicGenerations([baseline, first, second])
        #expect(output == ["g0: old", "g1: first", "g2: second"])
    } catch {
        Issue.record("\(error)")
    }
}

@Test func replacementsFromTwoModulesLoadFromOneImage() {
    let edits = ["FeatureA", "FeatureB"].enumerated().map { offset, module in
        let condition = "FEATURE_\(offset + 1)"
        return Loop.ModuleEdit(
            module: module,
            baseline: """
                public func value() -> String {
                #if \(condition)
                    "old-\(module)"
                #else
                    "wrong-flags"
                #endif
                }
                """,
            current: """
                public func value() -> String {
                #if \(condition)
                    "new-\(module)"
                #else
                    "wrong-flags"
                #endif
                }
                """,
            flags: ["-D", condition, "-swift-version", offset == 0 ? "5" : "6"])
    }

    do {
        let outcome = try Loop.runCrossModuleAtomic(edits)
        #expect(outcome.before == ["g0: old-FeatureA", "g0: old-FeatureB"])
        #expect(outcome.after.suffix(2) == ["g1: new-FeatureA", "g1: new-FeatureB"])
    } catch {
        Issue.record("\(error)")
    }
}
