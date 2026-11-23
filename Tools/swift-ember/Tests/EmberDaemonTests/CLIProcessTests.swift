import Darwin
import Foundation
import os
import Testing
import EmberCore
@testable import EmberCLI

@Test func humanStatusAndAlreadyRunningStartKeepTheirOutput() async throws {
    let fixture = try CLIFixture()
    let status = try fixture.launch("status")
    defer { status.cancel() }
    #expect(try await status.exitCode() == 0)
    #expect(try status.stdout() == """
        daemon             not running
        module             App
        target             arm64-apple-macosx14.0
        sdk                macosx
        compiler           swift-test
        bundle id          dev.example.App
        transport          simulator \(fixture.destination)
        app binary         /bin/sleep
        sources            \(fixture.sources.path)
        defines            \(String())
        build identity     App|arm64-apple-macosx14.0|macosx|swift-test

        """)
    let session = Lifecycle.session(for: fixture.options)
    try FileManager.default.createDirectory(
        at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Lifecycle.markReady(simulator: SimulatorSelection(identifier: fixture.destination, multipleBooted: false),
                            environment: ["SWIFT_EMBER_SESSION_RECORD": session.recordURL.path])
    let start = try fixture.launch("start")
    defer { start.cancel() }
    #expect(try await start.exitCode() == 0)
    #expect(try start.stdout() == """
        already running pid \(getpid())
        log                \(session.logURL.path)
        transport          simulator \(fixture.destination)

        """)
}

@Test func helpListsTheJSONOption() async throws {
    let fixture = try CLIFixture()
    let help = try fixture.launch("--help")
    defer { help.cancel() }
    #expect(try await help.exitCode() == 0)
    #expect(try help.stdout().contains("--json"))
}

@Test func humanWatchReportsTheDisconnect() async throws {
    let fixture = try CLIFixture()
    let watch = try fixture.launch("watch")
    defer { watch.cancel() }
    let session = try await fixture.waitForWatch(watch)
    let runtime = FakeRuntime(port: session.port)
    defer { runtime.disconnect() }
    try #require(await runtime.connect())
    try runtime.send(type: "hello", payload: Hello(
        token: session.token, buildIdentity: session.buildIdentity, moduleName: "dev.example.App",
        processId: 42, loadedGenerations: [], expectedBuildUUIDs: session.buildUUIDs, buildMatchesProcess: true))
    try await watch.waitForOutput("connected  pid 42, dev.example.App\n")
    runtime.disconnect()
    try await watch.waitForOutput("disconnected; waiting for the app to reconnect\n")
    watch.process.terminate()
    #expect(try await watch.exitCode() == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
}

@Test func watchKeepsRebuildChildOutputOutOfNDJSON() async throws {
    let fixture = try CLIFixture()
    let watch = try fixture.launch(
        "watch", extra: ["--json", "--rebuild-command",
                          "printf 'child stdout\\n'; printf 'child stderr\\n' >&2; exit 23"])
    defer { watch.cancel() }
    _ = try await fixture.waitForWatch(watch)
    try FileManager.default.removeItem(at: fixture.source)
    try await watch.waitForOutput("\"rebuild_failed\"")
    watch.process.terminate()
    #expect(try await watch.exitCode() == 0)
    let stdout = try watch.stdout()
    #expect(!stdout.contains("child stdout\n"))
    #expect(!stdout.contains("child stderr\n"))
    let events = try stdout.split(separator: "\n").map {
        let event = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        return try #require(event?["type"] as? String)
    }
    #expect(events.contains("rebuild_required"))
    #expect(events.contains("rebuild_started"))
    #expect(events.contains("rebuild_failed"))
    #expect(events.last == "stopped")
    #expect(try watch.stderr().hasSuffix("child stdout\nchild stderr\n"))
}

@Test(arguments: [OutputFailure.closed, .brokenPipe, .wouldBlock])
func stdoutFailureKeepsCLIExitCodesAndWatchCleanup(failure: OutputFailure) async throws {
    for extra in [[], ["--json"]] {
        let fixture = try CLIFixture()
        let status = try fixture.launch("status", extra: extra, failingOutput: failure)
        defer { status.cancel() }
        #expect(try await status.exitCode() == 0)
        let watch = try fixture.launch("watch", extra: extra, failingOutput: failure)
        defer { watch.cancel() }
        _ = try await fixture.waitForWatch(watch)
        watch.process.terminate()
        #expect(try await watch.exitCode() == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.savedContext.path))
    }
}

enum OutputFailure: String {
    case closed, brokenPipe, wouldBlock
}

private final class CLITestBundleMarker: NSObject {}

private final class CLIFixture {
    struct Session: Decodable {
        let port: UInt16
        let token: String
        let buildIdentity: String
        let buildUUIDs: [String]
    }

    let root: URL
    let destination = UUID().uuidString
    var sources: URL { root.appendingPathComponent("Sources") }
    var source: URL { sources.appendingPathComponent("App.swift") }
    var record: URL { root.appendingPathComponent("watch.json") }
    var savedContext: URL { root.appendingPathComponent("watch.context.json") }
    private var context: URL { root.appendingPathComponent("app.json") }
    private var developer: URL { root.appendingPathComponent("Developer") }
    private var container: URL { root.appendingPathComponent("Container") }

    var options: Options {
        var options = Options(command: .status, contextPath: context.path, simulator: destination)
        options.ignoresProjectConfiguration = true
        return options
    }

    init() throws {
        let manager = FileManager.default
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? manager.temporaryDirectory
        root = temporary.appendingPathComponent("ember-cli-process-\(UUID())", isDirectory: true)
            .standardizedFileURL
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("func greet() -> Int { 1 }\n".utf8).write(to: source)
        try BuildContext(
            moduleName: "App", swiftCompilerPath: "/usr/bin/swiftc", swiftCompilerVersion: "swift-test",
            targetTriple: "arm64-apple-macosx14.0", sdkPath: "/SDK", sdkName: "macosx",
            appBinaryPath: "/bin/sleep", moduleSearchPaths: [], extraCompilerFlags: [],
            sourceRoots: [sources.path], bundleIdentifier: "dev.example.App").write(to: context)

        // /usr/bin/xcrun delegates to a custom developer directory's xcrun.
        // Supply only the fixture container and UUID, with no real Simulator fallback.
        let tools = developer.appendingPathComponent("usr/bin")
        try manager.createDirectory(at: tools, withIntermediateDirectories: true)
        let xcrun = tools.appendingPathComponent("xcrun")
        try Data("""
            #!/bin/sh
            case "$1" in
                simctl)
                    [ "$2" = get_app_container ] && [ "$3" = "$EMBER_TEST_DESTINATION" ] || exit 64
                    printf '%s\\n' "$EMBER_TEST_CONTAINER"
                    ;;
                dwarfdump) printf 'UUID: 00000000-0000-4000-8000-000000000000 (arm64) fixture\\n' ;;
                *) exit 64 ;;
            esac

            """.utf8).write(to: xcrun)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func launch(_ command: String, extra: [String] = [], failingOutput: OutputFailure? = nil) throws -> CLIInvocation {
        let cli = Bundle(for: CLITestBundleMarker.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("swift-ember")
        try #require(FileManager.default.isExecutableFile(atPath: cli.path), "\(cli.path)")
        let process = Process()
        let arguments = [cli.path, command, "--no-config", "--context", context.path,
                         "--simulator", destination] + extra
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let closeStdout = failingOutput == .closed ? "exec 1>&-; " : ""
        process.arguments = ["-c", "trap '' PIPE; \(closeStdout)exec \"$@\"", "cli-test"] + arguments
        process.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developer.path
        environment["EMBER_TEST_DESTINATION"] = destination
        environment["EMBER_TEST_CONTAINER"] = container.path
        environment["SWIFT_EMBER_SESSION_RECORD"] = command == "watch" ? record.path : nil
        if command == "watch" {
            try FileManager.default.copyItem(at: context, to: savedContext)
        }
        environment["SWIFT_EMBER_PATCH_DIRECTORY"] = nil
        process.environment = environment
        return try CLIInvocation(process: process, directory: root, failingOutput: failingOutput)
    }

    func waitForWatch(_ watch: CLIInvocation) async throws -> Session {
        try await watch.waitUntil { FileManager.default.fileExists(atPath: record.path) }
        let session = container.appendingPathComponent("Documents/splice-session.json")
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: session))
    }
}

private final class CLIInvocation {
    let process: Process
    private let stdoutURL: URL
    private let stderrURL: URL
    private let outputPipe: Pipe?
    private let termination = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    init(process: Process, directory: URL, failingOutput: OutputFailure?) throws {
        self.process = process
        let prefix = directory.appendingPathComponent(UUID().uuidString)
        stdoutURL = prefix.appendingPathExtension("stdout")
        stderrURL = prefix.appendingPathExtension("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        if failingOutput == .brokenPipe || failingOutput == .wouldBlock {
            let pipe = Pipe()
            outputPipe = pipe
            if failingOutput == .brokenPipe {
                try pipe.fileHandleForReading.close()
            } else {
                let fd = pipe.fileHandleForWriting.fileDescriptor
                try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
                while write(fd, "x", 1) == 1 {}
                try #require(errno == EAGAIN)
            }
            process.standardOutput = pipe.fileHandleForWriting
        } else {
            outputPipe = nil
            process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        }
        process.terminationHandler = { [termination] process in
            termination.withLock { $0 = process.terminationStatus }
        }
        try process.run()
    }

    func stdout() throws -> String { try String(contentsOf: stdoutURL, encoding: .utf8) }
    func stderr() throws -> String { try String(contentsOf: stderrURL, encoding: .utf8) }

    func waitForOutput(_ text: String) async throws {
        try await waitUntil { try stdout().contains(text) }
    }

    func waitUntil(_ ready: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try ready() { return }
            if termination.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try ready()
        let details = try "stdout: \(stdout())\nstderr: \(stderr())"
        try #require(result, Comment(rawValue: details))
    }

    func exitCode() async throws -> Int32 {
        try await waitUntil { termination.withLock { $0 != nil } }
        return try #require(termination.withLock { $0 })
    }

    func cancel() {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}
