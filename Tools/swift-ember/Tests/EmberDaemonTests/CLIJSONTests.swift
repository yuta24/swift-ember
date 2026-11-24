import Darwin
import Foundation
import Testing
import EmberCore
import EmberDaemon
@testable import EmberCLI

private final class JSONLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func append(_ line: Data) {
        lock.withLock { lines.append(line) }
    }

    func read() -> [Data] {
        lock.withLock { lines }
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func reloadReport(_ timeline: StageTimeline, withDetails: Bool = false) -> ReloadReport {
    ReloadReport(
        generation: timeline.generation, declarations: ["App.render()"], carried: withDetails ? ["helper()"] : [],
        verified: !withDetails, registered: withDetails ? (3, 1) : nil, refreshed: withDetails ? "one view" : nil,
        oneShot: withDetails ? [
            OneShotNote(name: "App.viewDidLoad()", scope: .instance),
            OneShotNote(name: "App.didFinishLaunching()", scope: .process),
        ] : [], timeline: timeline)
}

@Test func watchEncodesAllEventsAndKeepsMultilineReasonsOnOneLine() throws {
    let lines = JSONLines()
    let output = WatchOutput(json: true, writeLine: lines.append)
    let rebuild = EmberError(stage: .classify, subject: "App.swift",
                             reason: "new stored property", recovery: .rebuild)
    let failure = EmberError(stage: .compile, subject: "App.swift",
                             reason: "first line\nsecond line\r\n\"quoted\"", recovery: .editAndRetry)
    let uncertain = EmberError(stage: .load, subject: "App", reason: "lost connection", recovery: .restart)
    let events: [(WatchEvent, String)] = [
        (.started(sourceRoots: ["/Sources"], buildOutputPaths: ["/Build"], port: 51237, simulator: "SIM", device: nil),
         "started"),
        (.connected(processId: 19, bundleIdentifier: "dev.example.App"), "connected"),
        (.connectionRefused(processId: 20, message: "build mismatch"), "connection_refused"),
        (.disconnected, "disconnected"),
        (.reloaded(reloadReport(StageTimeline(generation: 1))), "reloaded"),
        (.rejection(rebuild), "rebuild_required"),
        (.rejection(failure), "error"),
        (.sessionUncertain(uncertain), "session_uncertain"),
        (.warning("runtime diagnostic"), "warning"),
        (.rebuildStarted(directory: "/Project"), "rebuild_started"),
        (.rebuildCompleted(processId: 21), "rebuild_completed"),
        (.rebuildFailed("command exited with status 1"), "rebuild_failed"),
    ]
    for (event, _) in events { output.report(event) }
    output.finish()
    output.warning("late diagnostic")
    output.finish()

    let emitted = lines.read()
    let documents = try emitted.map(object)
    #expect(emitted.allSatisfy { $0.last == 10 && !$0.dropLast().contains(10) && !$0.contains(13) })
    #expect(documents.compactMap { $0["type"] as? String } == events.map { $0.1 } + ["stopped"])
    #expect(documents.compactMap { $0["seq"] as? Int } == Array(1...13))
    #expect(documents.allSatisfy { $0["v"] as? Int == 1 })
    let timestamp = ISO8601DateFormatter()
    #expect(documents.compactMap { $0["at"] as? String }.filter { timestamp.date(from: $0) != nil }.count == 13)

    let byType = Dictionary(uniqueKeysWithValues: documents.compactMap { doc in
        (doc["type"] as? String).map { ($0, doc) }
    })
    #expect(byType["started"]?["sourceRoots"] as? [String] == ["/Sources"])
    #expect(byType["started"]?["buildOutputPaths"] as? [String] == ["/Build"])
    #expect(byType["started"]?["port"] as? Int == 51237)
    #expect(byType["started"]?["simulator"] as? String == "SIM")
    #expect(byType["connected"]?["processId"] as? Int == 19)
    #expect(byType["connected"]?["bundleIdentifier"] as? String == "dev.example.App")
    #expect(byType["connection_refused"]?["processId"] as? Int == 20)
    #expect(byType["connection_refused"]?["message"] as? String == "build mismatch")
    for (type, error) in [("error", failure), ("rebuild_required", rebuild), ("session_uncertain", uncertain)] {
        let doc = try #require(byType[type])
        #expect(doc["stage"] as? String == error.stage.rawValue)
        #expect(doc["subject"] as? String == error.subject)
        #expect(doc["reason"] as? String == error.reason)
        #expect(doc["recovery"] as? String == error.recovery.rawValue)
    }
    #expect(byType["warning"]?["message"] as? String == "runtime diagnostic")
    #expect(byType["rebuild_started"]?["directory"] as? String == "/Project")
    #expect(byType["rebuild_completed"]?["processId"] as? Int == 21)
    #expect(byType["rebuild_failed"]?["message"] as? String == "command exited with status 1")
}

@Test func simultaneousWatchCallbacksWriteInSequenceOrder() throws {
    let lines = JSONLines()
    let output = WatchOutput(json: true, writeLine: lines.append)
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        output.warning("diagnostic \(index)")
    }
    output.finish()
    let documents = try lines.read().map(object)
    #expect(documents.compactMap { $0["seq"] as? Int } == Array(1...33))
    #expect(documents.last?["type"] as? String == "stopped")
}

// `JSONSerialization` occasionally returns a `Double` that is not bit-identical to the one
// that was written, so the exact timing comparisons read the same line with `JSONDecoder`.
private struct DecodedReloadTimings: Decodable {
    struct StageTiming: Decodable {
        let durationMs: Double
    }

    let timings: [StageTiming]
    let totalMs: Double
}

@Test(arguments: [true, false])
func reloadedHasStableKeysAndOnlyMeasuredStages(withDetails: Bool) throws {
    let timeline = StageTimeline(generation: 7)
    timeline.measure(.classify) {}
    timeline.measure(.link) {}
    let lines = JSONLines()
    WatchOutput(json: true, writeLine: lines.append)
        .report(.reloaded(reloadReport(timeline, withDetails: withDetails)))
    let event = try object(#require(lines.read().first))
    #expect(Set(event.keys) == [
        "v", "type", "seq", "at", "generation", "declarations", "carried", "verified",
        "registered", "refreshed", "oneShot", "timings", "totalMs",
    ])
    #expect(event["generation"] as? UInt64 == 7)
    #expect(event["declarations"] as? [String] == ["App.render()"])
    #expect(event["verified"] as? Bool == !withDetails)
    if withDetails {
        #expect(event["carried"] as? [String] == ["helper()"])
        #expect(event["registered"] as? [String: Int] == ["counted": 3, "expected": 1])
        #expect(event["refreshed"] as? String == "one view")
        #expect(event["oneShot"] as? [[String: String]] == [
            ["name": "App.viewDidLoad()", "scope": "instance"],
            ["name": "App.didFinishLaunching()", "scope": "process"],
        ])
    } else {
        #expect(event["registered"] is NSNull)
        #expect(event["refreshed"] is NSNull)
        #expect((event["oneShot"] as? [[String: String]])?.isEmpty == true)
    }
    let timings = try #require(event["timings"] as? [[String: Any]])
    #expect(timings.compactMap { $0["stage"] as? String } == ["CLASSIFY", "LINK"])
    #expect(timings.allSatisfy { $0["success"] as? Bool == true && $0["generation"] as? Int == 7 })
    let line = try #require(lines.read().first)
    let decoded = try JSONDecoder().decode(DecodedReloadTimings.self, from: line)
    #expect(decoded.timings.map(\.durationMs) == timeline.all.map(\.durationMs))
    #expect(decoded.totalMs == timeline.totalMs)
}

@Test func humanReloadTextAndRuntimeMessageKeepTheirExistingLayout() {
    let timeline = StageTimeline(generation: 7)
    let lines = JSONLines()
    let output = WatchOutput(json: false, writeLine: lines.append)
    var text = ""
    let message = output.reportReload(reloadReport(timeline, withDetails: true), summary: timeline.summary()) {
        text += $0 + "\n"
    }
    output.finish()
    #expect(lines.read().isEmpty)
    let reload = """
    hot reloaded 1 declaration in 0 ms  (g7)
      App.render()
      carried: helper()
      not verified: the image carries 3 replacement records and 1 was generated
      refreshed: one view
      already ran: App.viewDidLoad()
      replaced, but UIKit will not call it again for anything that
      already exists; the next instance of that type runs the new body
      already ran: App.didFinishLaunching()
      there is one of these per process, and relaunching starts from the
      built binary, so seeing this change takes a build
    """
    #expect(text == "\n" + reload + "\n--------------------------------\ntotal                      0 ms\n\n")
    #expect(message == RuntimeLogMessage(level: .warning, message: reload))
}

@Test(arguments: [true, false])
func statusJSONShowsSessionStateWithoutExposingSigningDetails(isRunning: Bool) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ember-status-output-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let options = try Options.parse([
        "status", "--json", "--context", root.appendingPathComponent("app.json").path,
        "--rebuild-command", "build-app", "--rebuild-directory", root.path, "--rebuild-timeout", "25",
    ])
    let session = Lifecycle.session(for: options)
    if isRunning {
        try FileManager.default.createDirectory(
            at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Lifecycle.markReady(simulator: SimulatorSelection(identifier: "SIM", multipleBooted: true),
                                environment: ["SWIFT_EMBER_SESSION_RECORD": session.recordURL.path])
    }
    let context = BuildContext(
        moduleName: "App", swiftCompilerPath: "/tool/swiftc", swiftCompilerVersion: "Swift 6.0",
        targetTriple: "arm64-apple-ios16.0-simulator", sdkPath: "/SDK", sdkName: "iphonesimulator",
        appBinaryPath: "/App", moduleSearchPaths: ["/private/modules"], extraCompilerFlags: ["-D", "DEBUG"],
        sourceRoots: ["/Sources"], bundleIdentifier: "dev.example.App", codeSigningIdentity: "fixture identity")
    let running = Lifecycle.runningSession(options: options)
    let report = StatusDocument(running: running, session: session, context: context, options: options)
    let doc = try object(JSONEncoder().encode(report))
    #expect(doc["v"] as? Int == 1)
    #expect(doc["type"] as? String == "status")
    let daemon = try #require(doc["daemon"] as? [String: Any])
    #expect(daemon["running"] as? Bool == isRunning)
    #expect(daemon["pid"] as? Int32 == (isRunning ? getpid() : nil))
    #expect(daemon["simulator"] as? String == (isRunning ? "SIM" : nil))
    #expect((daemon["warning"] as? String)?.contains("multiple Simulators") == (isRunning ? true : nil))
    let paths = try #require(doc["session"] as? [String: String])
    #expect(paths == [
        "record": session.recordURL.path, "context": session.contextURL.path, "log": session.logURL.path,
        "patches": session.patchURL.path, "lock": session.lockURL.path,
    ])
    let reportedContext = try #require(doc["context"] as? [String: Any])
    #expect(reportedContext["moduleName"] as? String == "App")
    #expect(reportedContext["extraCompilerFlags"] as? [String] == ["-D", "DEBUG"])
    #expect(reportedContext["codeSigningIdentity"] == nil)
    #expect(reportedContext["moduleSearchPaths"] == nil)
    let rebuild = try #require(doc["rebuild"] as? [String: Any])
    #expect(rebuild["command"] as? String == "build-app")
    #expect(rebuild["directory"] as? String == root.path)
    #expect(rebuild["timeoutSeconds"] as? Double == 25)
}

@Test func startDocumentReportsOneResult() throws {
    for (kind, type): (StartDocument.Kind, String) in [(.started, "started"), (.alreadyRunning, "already_running")] {
        let lines = JSONLines()
        CLIJSON.write(StartDocument(type: kind, pid: 42, log: "/watch.log", simulator: "SIM", warning: "warning"),
                      to: lines.append)
        let emitted = lines.read()
        #expect(emitted.count == 1)
        let doc = try object(#require(emitted.first))
        #expect(doc["v"] as? Int == 1)
        #expect(doc["type"] as? String == type)
        #expect(doc["pid"] as? Int == 42)
        #expect(doc["log"] as? String == "/watch.log")
        #expect(doc["simulator"] as? String == "SIM")
        #expect(doc["warning"] as? String == "warning")
    }
}

@Test func rebuildChildStreamsGoToTheDiagnosticDescriptorInJSONMode() async throws {
    let directory = FileManager.default.temporaryDirectory
    let childLog = directory.appendingPathComponent("ember-rebuild-output-\(UUID())")
    try Data().write(to: childLog)
    defer { try? FileManager.default.removeItem(at: childLog) }
    let diagnostics = try FileHandle(forWritingTo: childLog)
    defer { try? diagnostics.close() }
    let lines = JSONLines()
    let output = WatchOutput(json: true, writeLine: lines.append)
    output.report(.rebuildStarted(directory: directory.path))
    try await RebuildCommand.Runner().run(
        "printf 'child stdout\\n'; printf 'child stderr\\n' >&2", in: directory, output: diagnostics)
    output.report(.rebuildCompleted(processId: 42))

    #expect(try String(contentsOf: childLog, encoding: .utf8) == "child stdout\nchild stderr\n")
    let objects = try lines.read().map(object)
    #expect(objects.compactMap { $0["type"] as? String } == ["rebuild_started", "rebuild_completed"])
}
