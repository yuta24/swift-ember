// The runtime's FR-13 reader, run against a real loaded image.
//
// `RegisteredReplacements` decides whether a patch that loaded actually
// carries what was asked for, and a wrong answer either ends a healthy session
// or blesses a broken one. It is ~150 lines of raw pointer walking over two
// layouts that are measured rather than documented, so it is compiled into
// this application -- `EXTRA_SOURCES` in case.conf -- and asked about the
// image the harness just loaded.
//
// The subject mixes all three shapes it has to count, because they arrive by
// different mechanisms and the total is what the daemon compares:
//
//   plain method        one __swift5_replace record
//   @objc method        an Objective-C category, no record at all
//   @objc get/set       a category again, and one implementation per accessor
//
// Expected total is 1 + 1 + 2 = 4, and the fourth declaration is the reason
// the count is not simply "how many bodies did this image bring". It is
// *carried*: the patch adds it, it replaces nothing, and it must not be
// counted. It sits in the `@objcMembers` class so that it becomes `@objc` and
// lands in the same category as the replacements -- exactly the shape that
// once made a patch whose replacement was missing add up to the expected
// total and report a verified reload.
//
// Which class each declaration lives in is therefore load-bearing in both
// directions, and the split below is not tidiness. A toolchain that changes
// either layout should break this rather than somebody's session.

import Foundation

/// Deliberately not `@objcMembers`, and deliberately not the class below.
///
/// `@objcMembers` reaches every member, so putting this method beside the
/// others made it `@objc` too and the image stopped carrying a
/// `__swift5_replace` section at all. The total stayed 4 and the case still
/// passed, while the entire Swift-section half of the reader --- the section
/// lookup, the scope walk, the bounds guards --- went unexercised. This is the
/// only place that half runs.
class Plain {
    func plain() -> String { "old" }
}

@objcMembers class Counter: NSObject {
    var storage = 0

    @objc func objcMethod() -> String { "old" }

    @objc var objcProperty: Int {
        get { storage }
        set { storage = newValue }
    }
}

func probe() async throws -> [String] {
    CommandLine.arguments.dropFirst().map { path in
        let name = (path as NSString).lastPathComponent
        guard let count = RegisteredReplacements.count(inImageAt: path) else {
            // Before the harness loads it, the image is not in the process and
            // there is nothing to read. That is the honest answer, and it is
            // the same one a corrupted section gets.
            return "\(name): not loaded"
        }
        return "\(name): \(count)"
    }
}
