import Foundation
import Testing
import EmberCore
@testable import EmberCLI
@testable import EmberDaemon

private func withWatcher(
    _ operation: (URL, FileWatcher) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-file-watcher-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root, FileWatcher(roots: [root]))
}

private func write(_ source: String, to url: URL) throws {
    try Data(source.utf8).write(to: url, options: .atomic)
}

@Test func primingDoesNotReportExistingSources() throws {
    try withWatcher { root, watcher in
        try write("struct Existing {}", to: root.appendingPathComponent("Existing.swift"))
        try watcher.prime()
        #expect(try watcher.poll().isEmpty)
    }
}

@Test func addingAndModifyingASourceAreDistinguished() throws {
    try withWatcher { root, watcher in
        try watcher.prime()
        let source = root.appendingPathComponent("Feature.swift")

        try write("struct Feature {}", to: source)
        #expect(try watcher.poll() == [.init(url: source, kind: .added)])

        // Pick a deterministic value instead of depending on the filesystem's
        // timestamp resolution when the two writes happen in the same test.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        #expect(try watcher.poll() == [.init(url: source, kind: .modified)])
    }
}

@Test func removingASourceIsReported() throws {
    try withWatcher { root, watcher in
        let source = root.appendingPathComponent("Removed.swift")
        try write("struct Removed {}", to: source)
        try watcher.prime()

        try FileManager.default.removeItem(at: source)
        #expect(try watcher.poll() == [.init(url: source, kind: .removed)])
    }
}

@Test func renamingASourceReportsBothHalvesInOnePoll() throws {
    try withWatcher { root, watcher in
        let old = root.appendingPathComponent("Old.swift")
        let new = root.appendingPathComponent("New.swift")
        try write("struct Feature {}", to: old)
        try watcher.prime()

        try FileManager.default.moveItem(at: old, to: new)
        #expect(try watcher.poll() == [
            .init(url: new, kind: .added),
            .init(url: old, kind: .removed),
        ])
    }
}

@Test func anAtomicSaveRemainsAModification() throws {
    try withWatcher { root, watcher in
        let source = root.appendingPathComponent("Atomic.swift")
        try write("struct Atomic { let value = 1 }", to: source)
        try watcher.prime()

        try write("struct Atomic { let value = 2 }", to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        #expect(try watcher.poll() == [.init(url: source, kind: .modified)])
    }
}

@Test func nonSwiftFilesAreIgnored() throws {
    try withWatcher { root, watcher in
        try watcher.prime()
        try write("notes", to: root.appendingPathComponent("Notes.txt"))
        #expect(try watcher.poll().isEmpty)
    }
}

@Test func excludedFilesAndDirectoriesDoNotProduceChanges() throws {
    try withWatcher { root, _ in
        let generated = root.appendingPathComponent("Generated", isDirectory: true)
        let ignoredFile = root.appendingPathComponent("Ignored.swift")
        let includedFile = root.appendingPathComponent("Included.swift")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try write("struct Generated {}", to: generated.appendingPathComponent("Generated.swift"))
        try write("struct Ignored {}", to: ignoredFile)
        try write("struct Included {}", to: includedFile)

        let watcher = FileWatcher(roots: [root], excluding: [generated, ignoredFile])
        try watcher.prime()

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: generated.appendingPathComponent("Generated.swift").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: ignoredFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: includedFile.path)

        #expect(try watcher.poll() == [.init(url: includedFile, kind: .modified)])
    }
}

@Test func exclusionsRespectPathComponentBoundaries() {
    let filter = SourcePathFilter(excluding: [URL(fileURLWithPath: "/project/Sources")])

    #expect(filter.excludes(URL(fileURLWithPath: "/project/Sources/Feature.swift")))
    #expect(filter.excludes(URL(fileURLWithPath: "/project/Sources")))
    #expect(!filter.excludes(URL(fileURLWithPath: "/project/SourcesExtra/Feature.swift")))
}

@Test func anIncompleteScanPreservesTheLastCompleteSnapshot() throws {
    try withWatcher { root, watcher in
        let source = root.appendingPathComponent("Feature.swift")
        let unavailable = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-unavailable", isDirectory: true)
        try write("struct Feature { let value = 1 }", to: source)
        try watcher.prime()

        try FileManager.default.moveItem(at: root, to: unavailable)
        defer {
            if FileManager.default.fileExists(atPath: unavailable.path),
               !FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.moveItem(at: unavailable, to: root)
            }
            try? FileManager.default.removeItem(at: unavailable)
        }
        #expect(throws: FileWatcher.ScanFailure.self) {
            try watcher.poll()
        }

        try FileManager.default.moveItem(at: unavailable, to: root)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        #expect(try watcher.poll() == [.init(url: source, kind: .modified)])
    }
}

@Test func aRemovalRejectsTheWholeBatch() throws {
    try withWatcher { root, _ in
        let old = root.appendingPathComponent("Old.swift")
        let new = root.appendingPathComponent("New.swift")
        var guardState = Watch.RemovalGuard()
        let checked = guardState.check([
            .init(url: new, kind: .added),
            .init(url: old, kind: .removed),
        ])
        let error = try #require(checked)
        #expect(error.stage == .classify)
        #expect(error.reason.contains("Old.swift"))
        #expect(error.reason.contains("this batch cannot be applied safely"))
        #expect(error.reason.contains("restart the watcher"))
        #expect(error.reason.contains("`xcode start` Build post-action"))
        #expect(error.recovery == .rebuild)
    }
}

@Test func anOrdinaryModificationDoesNotRejectTheBatch() {
    var guardState = Watch.RemovalGuard()
    let change = FileWatcher.Change(
        url: URL(fileURLWithPath: "/project/Sources/Feature.swift"), kind: .modified)
    let checked = guardState.check([change])
    #expect(checked == nil)
}

@Test func aRenameKeepsRejectingChangesUntilTheWatcherRestarts() throws {
    try withWatcher { root, _ in
        let old = root.appendingPathComponent("Old.swift")
        let new = root.appendingPathComponent("New.swift")
        let unrelated = root.appendingPathComponent("Unrelated.swift")
        var guardState = Watch.RemovalGuard()

        let initial = guardState.check([
            .init(url: new, kind: .added),
            .init(url: old, kind: .removed),
        ])
        #expect(initial != nil)

        // Even an exact restoration cannot replay another file changed in a
        // rejected batch. A rebuild starts a fresh watcher and baseline.
        try write("struct Restored {}", to: old)
        let restored = guardState.check([
            .init(url: old, kind: .added),
        ])
        #expect(restored != nil)

        let checked = guardState.check([
            .init(url: unrelated, kind: .modified),
        ])
        let later = try #require(checked)
        #expect(later.reason.contains("Old.swift"))
    }
}
