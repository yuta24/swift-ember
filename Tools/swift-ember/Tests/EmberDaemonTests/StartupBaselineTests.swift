import Foundation
import Testing
import EmberCore
@testable import EmberCLI
@testable import EmberDaemon

@Suite(.serialized)
struct StartupBaselineTests {
    private let original = """
    func first() -> String { "first-v1" }
    func second() -> String { "second-v1" }
    """

    @Test(arguments: [false, true])
    func anEditBetweenBuildAndWatchRequiresRebuild(signatureChange: Bool) async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        let edited = signatureChange
            ? original.replacingOccurrences(of: "first()", with: "first(_ value: Int)")
            : original.replacingOccurrences(of: "first-v1", with: "first-v2")
        try fixture.save(edited)

        let failure = await #expect(throws: EmberError.self) {
            try await Watch.run(context: fixture.context, workDirectory: fixture.patch.deletingLastPathComponent(),
                                onReady: { Issue.record("watcher accepted sources that differ from the build") })
        }
        #expect(failure?.stage == .watch)
        #expect(failure?.recovery == .rebuild)
        #expect(failure?.reason.contains(fixture.source.path) == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.patch.path))
        #expect(try fixture.reportFromUnpatchedProcess() == "first-v1|second-v1|\(fixture.process.processIdentifier)")
    }

    @Test func anEditAfterVerificationReachesTheRunningProcessOnTheFirstPoll() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        let snapshot = try fixture.manifest.snapshot()
        let verified = try fixture.manifest.validate(snapshot)
        let uuids = try #require(verified)
        let date = try #require(fixture.source.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)

        try fixture.save(original.replacingOccurrences(of: "first-v1", with: "first-v2"))
        // Atomic saves can replace a file without changing its modification time.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.source.path)
        await fixture.coordinator.primeBaselines(from: snapshot, buildUUIDs: uuids)
        let watcher = FileWatcher(roots: [fixture.sources])
        watcher.prime(from: snapshot)

        #expect(try watcher.poll() == [.init(url: fixture.source, kind: .modified)])
        #expect(try watcher.poll().isEmpty)
        try await fixture.compileWithoutSocket()
        let generated = try String(contentsOf: fixture.patchSource, encoding: .utf8)
        #expect(generated.contains("for: first()"))
        #expect(!generated.contains("for: second()"))
        #expect(try await fixture.loadIntoRunningProcess() == "first-v2|second-v1|\(fixture.process.processIdentifier)")
    }

    @Test(arguments: [false, true])
    func aFailedReadDoesNotInstallAnyBaseline(invalidUTF8: Bool) async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        let valid = fixture.sources.appendingPathComponent("Other.swift")
        try "func other() {}".write(to: valid, atomically: true, encoding: .utf8)
        if invalidUTF8 {
            try Data([0xFF, 0xFE, 0xFF]).write(to: fixture.source)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.source.path)
        }

        let failure = await #expect(throws: EmberError.self) {
            try await fixture.coordinator.primeBaselines(from: [fixture.sources])
        }
        #expect(failure?.stage == .watch)
        #expect(failure?.recovery == .configure)
        #expect(failure?.reason.contains(fixture.source.path) == true)
        #expect(!(await fixture.coordinator.hasBaseline(for: fixture.source)))
        #expect(!(await fixture.coordinator.hasBaseline(for: valid)))
    }

    @Test func aFailedEnumerationDoesNotInstallAnyBaseline() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        let missing = fixture.root.appendingPathComponent("Missing")
        let failure = await #expect(throws: EmberError.self) {
            try await fixture.coordinator.primeBaselines(from: [fixture.sources, missing])
        }
        #expect(failure?.stage == .watch)
        #expect(failure?.recovery == .configure)
        #expect(failure?.reason.contains(missing.path) == true)
        #expect(!(await fixture.coordinator.hasBaseline(for: fixture.source)))
    }

    @Test func aNoOpBuildPreservesOnlyAnExistingMatchingProof() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        try fixture.manifest.prepare()
        try fixture.manifest.record()
        #expect(try fixture.manifest.validate(fixture.manifest.snapshot()) != nil)

        try fixture.save(original.replacingOccurrences(of: "first-v1", with: "first-v2"))
        try fixture.manifest.prepare()
        let failure = #expect(throws: EmberError.self) { try fixture.manifest.record() }
        #expect(failure?.recovery == .rebuild)
        #expect(failure?.reason.contains("UUIDs") == true)
    }

    @Test func anEditDuringBuildCannotBeRecordedEvenIfTheOriginalBytesAreRestored() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        try fixture.manifest.prepare()
        try fixture.save(original.replacingOccurrences(of: "first-v1", with: "first-v2"))
        try fixture.save(original)
        let failure = #expect(throws: EmberError.self) { try fixture.manifest.record() }
        #expect(failure?.reason.contains(fixture.source.path) == true)
        let startup = #expect(throws: EmberError.self) {
            try fixture.manifest.validate(fixture.manifest.snapshot())
        }
        #expect(startup?.recovery == .rebuild)
    }

    @Test func aStaleUUIDIsRejectedEvenWhenTheSourcesMatch() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        try FileManager.default.removeItem(atPath: fixture.context.linkTarget)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: fixture.context.linkTarget)
        let failure = #expect(throws: EmberError.self) {
            try fixture.manifest.validate(fixture.manifest.snapshot())
        }
        #expect(failure?.stage == .watch)
        #expect(failure?.recovery == .rebuild)
        #expect(failure?.reason.contains("does not match the Mach-O UUIDs") == true)
    }

    @Test func missingProofIsLegacyButMalformedProofIsRejected() async throws {
        let fixture = try await StartupFixture.build(original)
        defer { fixture.stop() }
        let snapshot = try fixture.manifest.snapshot()
        try FileManager.default.removeItem(at: fixture.manifest.url)
        #expect(try fixture.manifest.validate(snapshot) == nil)
        try Data("{".utf8).write(to: fixture.manifest.url)
        let failure = #expect(throws: EmberError.self) { try fixture.manifest.validate(snapshot) }
        #expect(failure?.recovery == .rebuild)
        #expect(failure?.subject == fixture.manifest.url.path)
    }
}

private struct StartupFixture {
    let root: URL
    let sources: URL
    let source: URL
    let patch: URL
    let patchSource: URL
    let context: BuildContext
    let coordinator: PatchCoordinator
    let server: IPCServer
    let process: Process
    let input: Pipe
    let report: URL

    static func build(_ original: String) async throws -> StartupFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ember-startup-baseline-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("Subject.swift")
        try original.write(to: source, atomically: true, encoding: .utf8)
        let report = root.appendingPathComponent("report.txt")
        let driver = root.appendingPathComponent("Driver.swift")
        try """
        import Foundation
        @main enum Driver {
            static func main() throws {
                let report = URL(fileURLWithPath: CommandLine.arguments[1])
                func record() throws {
                    try "\\(first())|\\(second())|\\(ProcessInfo.processInfo.processIdentifier)"
                        .write(to: report, atomically: true, encoding: .utf8)
                }
                try record()
                while let path = readLine() {
                    if path == "quit" { return }
                    guard dlopen(path, RTLD_NOW) != nil else {
                        throw NSError(domain: String(cString: dlerror()), code: 1)
                    }
                    try record()
                }
            }
        }
        """.write(to: driver, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("Startup.app/Contents/MacOS/Startup")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let compiler = try tool(["--find", "swiftc"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sdk = try tool(["--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetData = Data(try tool(["swiftc", "-print-target-info"]).utf8)
        let info = try #require(JSONSerialization.jsonObject(with: targetData) as? [String: Any])
        let target = try #require(info["target"] as? [String: Any])
        let triple = try #require(target["triple"] as? String)
        let context = BuildContext(
            moduleName: "StartupApp", swiftCompilerPath: compiler, swiftCompilerVersion: "startup-test",
            targetTriple: triple, sdkPath: sdk, sdkName: "macosx", appBinaryPath: binary.path,
            moduleSearchPaths: [root.path], extraCompilerFlags: [], sourceRoots: [sources.path],
            bundleIdentifier: "dev.swift-ember.startup-baseline")
        let manifest = BuildSourceManifest(context: context)
        try manifest.prepare()
        _ = try tool([
            "swiftc", "-Onone", "-enable-testing", "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-private-imports", "-parse-as-library", "-module-name", "StartupApp",
            "-emit-module", "-emit-module-path", root.appendingPathComponent("StartupApp.swiftmodule").path,
            "-emit-executable", "-o", binary.path, driver.path, source.path,
        ])
        // Scheme actions are separate CLI invocations, so resolve the manifest
        // location again after the link target has been created.
        try BuildSourceManifest(context: context).record()
        let server = try IPCServer()
        let patches = root.appendingPathComponent("patches")
        let coordinator = PatchCoordinator(context: context, server: server, workDirectory: patches,
                                           deliver: { $0 })
        let process = Process()
        let input = Pipe()
        process.executableURL = binary
        process.arguments = [report.path]
        process.standardInput = input
        try process.run()
        let fixture = StartupFixture(
            root: root, sources: sources, source: source,
            patch: patches.appendingPathComponent("Patch_001.dylib"),
            patchSource: patches.appendingPathComponent("Patch_001.swift"),
            context: context, coordinator: coordinator, server: server,
            process: process, input: input, report: report)
        do {
            let before = try await fixture.waitForReport()
            #expect(before == "first-v1|second-v1|\(process.processIdentifier)")
        } catch {
            fixture.stop()
            throw error
        }
        return fixture
    }

    var manifest: BuildSourceManifest { BuildSourceManifest(context: context) }

    func reportFromUnpatchedProcess() throws -> String {
        try String(contentsOf: report, encoding: .utf8)
    }

    func save(_ sourceText: String) throws {
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
    }

    func compileWithoutSocket() async throws {
        // Exercise production classification, generation, compilation and linking.
        // The sandbox denies listening sockets. Delivery is an identity function,
        // and the child loads the resulting image through stdin below.
        guard case .rejected(let error) = await coordinator.handle(change: source) else {
            Issue.record("expected LOAD to stop at the disconnected socket transport")
            return
        }
        #expect(error.stage == .load, "\(error)")
        #expect(FileManager.default.fileExists(atPath: patch.path))
    }

    func loadIntoRunningProcess() async throws -> String {
        try FileManager.default.removeItem(at: report)
        try input.fileHandleForWriting.write(contentsOf: Data((patch.path + "\n").utf8))
        return try await waitForReport()
    }

    private func waitForReport() async throws -> String {
        for _ in 0..<250 {
            if let value = try? String(contentsOf: report, encoding: .utf8), !value.isEmpty { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "startup probe did not report before the 5-second deadline", code: 1)
    }

    func stop() {
        try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
        try? input.fileHandleForWriting.close()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static func tool(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "xcrun \(arguments.joined(separator: " ")): \(text)", code: Int(process.terminationStatus))
        }
        return text
    }
}
