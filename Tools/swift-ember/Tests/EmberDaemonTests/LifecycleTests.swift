import Darwin
import Foundation
import Testing
@testable import EmberCLI

private func temporaryOptions(_ name: String = UUID().uuidString) -> (Options, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-ember-lifecycle-\(name)")
    let context = root.appendingPathComponent("ember-context.json")
    return (Options(command: .status, contextPath: context.path), root)
}

private func rewriteRecord(at url: URL, key: String, value: Any) throws {
    let data = try Data(contentsOf: url)
    var record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    record[key] = value
    try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
}

@Test func backgroundWatcherKeepsOnlyStableToolEnvironment() {
    let environment = Lifecycle.backgroundEnvironment(from: [
        "HOME": "/Users/me",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": "/tmp/session",
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        "LANG": "en_US.UTF-8",
        "CONFIGURATION": "Debug",
        "SRCROOT": "/project",
        "DYLD_INSERT_LIBRARIES": "/tmp/debugger.dylib",
    ])

    #expect(environment == [
        "HOME": "/Users/me",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": "/tmp/session",
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        "LANG": "en_US.UTF-8",
    ])
}

@Test func sessionIdentityIsStableAndDistinguishesConfigurationAndDevice() {
    var first = Options(command: .start, project: "App.xcodeproj", scheme: "App")
    let same = Options(command: .stop, project: "./App.xcodeproj", scheme: "App")
    #expect(Lifecycle.session(for: first).name == Lifecycle.session(for: same).name)

    first.configuration = "Release"
    #expect(Lifecycle.session(for: first).name != Lifecycle.session(for: same).name)
    #expect(Lifecycle.session(for: first).patchURL != Lifecycle.session(for: same).patchURL)

    first.configuration = "Debug"
    first.device = "DEVICE-ID"
    #expect(Lifecycle.session(for: first).name != Lifecycle.session(for: same).name)
}

@Test func watchInvocationsSelectIsolatedPatchDirectories() {
    let (options, _) = temporaryOptions()
    let selected = Lifecycle.patchDirectory(for: options, environment: [
        "SWIFT_EMBER_PATCH_DIRECTORY": "/tmp/swift-ember/session-a",
    ])
    #expect(selected.path == "/tmp/swift-ember/session-a")

    let first = Lifecycle.patchDirectory(for: options, environment: [:])
    let second = Lifecycle.patchDirectory(for: options, environment: [:])
    #expect(first.deletingLastPathComponent() == Lifecycle.session(for: options).patchURL)
    #expect(first != second)
}

@Test func sessionLockSerializesConcurrentOperations() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let contender = session.lockURL.path.withCString {
        open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
    }
    try #require(contender >= 0)
    defer { close(contender) }

    try Lifecycle.withSessionLock(session) {
        errno = 0
        let result = flock(contender, LOCK_EX | LOCK_NB)
        let lockError = errno
        #expect(result == -1)
        #expect(lockError == EWOULDBLOCK)
    }

    try #require(flock(contender, LOCK_EX | LOCK_NB) == 0)
    #expect(flock(contender, LOCK_UN) == 0)
}

@Test func aReadyRecordFindsOnlyItsOwningProcess() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let environment = ["SWIFT_EMBER_SESSION_RECORD": session.recordURL.path]
    try Data("context".utf8).write(to: session.contextURL)

    try Lifecycle.markReady(environment: environment)
    #expect(Lifecycle.runningPID(options: options) == getpid())

    Lifecycle.removeOwnedRecord(environment: environment)
    #expect(!FileManager.default.fileExists(atPath: session.recordURL.path))
    #expect(!FileManager.default.fileExists(atPath: session.contextURL.path))
}

@Test func stopRemovesAStaleRecordWithoutSignallingAnything() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A process this high cannot exist on macOS (pid_t is a signed Int32).
    let data = Data(
        #"{"pid":2147483647,"executablePath":"/bin/sleep","startedAtMicroseconds":0}"#.utf8)
    try data.write(to: session.recordURL)
    try Data("context".utf8).write(to: session.contextURL)

    try Lifecycle.stop(options: options)
    #expect(!FileManager.default.fileExists(atPath: session.recordURL.path))
    #expect(!FileManager.default.fileExists(atPath: session.contextURL.path))
}

@Test func aCorruptRecordIsTreatedAsStale() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: session.recordURL)

    try Lifecycle.stop(options: options)
    #expect(!FileManager.default.fileExists(atPath: session.recordURL.path))
}

@Test func stopRefusesARecordWhosePIDWasReusedByAnotherExecutable() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Lifecycle.markReady(environment: ["SWIFT_EMBER_SESSION_RECORD": session.recordURL.path])
    try rewriteRecord(at: session.recordURL, key: "executablePath", value: "/bin/sleep")

    #expect(throws: Lifecycle.LifecycleError.self) {
        try Lifecycle.stop(options: options)
    }
}

@Test func stopRefusesAReusedPIDForTheSameExecutable() throws {
    let (options, root) = temporaryOptions()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Lifecycle.session(for: options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Lifecycle.markReady(environment: ["SWIFT_EMBER_SESSION_RECORD": session.recordURL.path])

    // A reused PID can still point at the same installed swift-ember binary.
    // Its kernel start time distinguishes that process from the recorded one.
    try rewriteRecord(at: session.recordURL, key: "startedAtMicroseconds", value: 0)

    #expect(Lifecycle.runningPID(options: options) == nil)
    #expect(throws: Lifecycle.LifecycleError.self) {
        try Lifecycle.stop(options: options)
    }
}
