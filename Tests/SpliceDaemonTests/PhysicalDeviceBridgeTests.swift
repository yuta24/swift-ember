import Foundation
import Testing
import SpliceCore
@testable import SpliceDaemon

private struct TestDeviceLoadReply: Codable {
    let result: LoadPatchResult
    let processId: Int32
}

private struct TestDeviceLoadCommand: Codable {
    let token: String
    let request: LoadPatchRequest
    let expiresAt: Date
}

private struct TestDeviceStatus: Codable {
    let protocolVersion: Int
    let token: String
    let buildIdentity: String
    let processId: Int32
    let loadedGenerations: [UInt64]
    let buildMatchesProcess: Bool
}

private final class DeviceCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(String, [String])] = []
    var appTeam = "TEAM"
    var patchTeam = "TEAM"
    var requestToken: String?
    private var response: Data?
    var status: Data?

    func run(_ executable: String, _ arguments: [String]) throws -> Subprocess.Result {
        lock.withLock { calls.append((executable, arguments)) }

        if executable == "/usr/bin/codesign", arguments.first == "-d" {
            let path = arguments.last ?? ""
            let team = path.contains("Patch_") ? patchTeam : appTeam
            return .init(exitCode: 0, combinedOutput: "TeamIdentifier=\(team)\n")
        }
        if executable == "/usr/bin/codesign" {
            return .init(exitCode: 0, combinedOutput: "")
        }

        if let destination = value(after: "--destination", in: arguments),
           destination == "Documents/SpliceRequests",
           let source = value(after: "--source", in: arguments),
           let file = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil).first {
            let request = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
            requestToken = try request.decode(TestDeviceLoadCommand.self).token
            let result = LoadPatchResult.loaded(generation: 1, durationMs: 2,
                                                registered: 1, refreshed: "layout")
            let deviceReply = TestDeviceLoadReply(result: result, processId: 42)
            let reply = try Envelope(type: "loadResult", requestId: request.requestId,
                                     payload: deviceReply)
            response = try JSONEncoder().encode(reply)
        }

        if arguments.prefix(4) == ["devicectl", "device", "copy", "from"],
           let destination = value(after: "--destination", in: arguments),
           let source = value(after: "--source", in: arguments) {
            let data = source.hasSuffix("splice-device-status.json") ? status : response
            if let data { try data.write(to: URL(fileURLWithPath: destination), options: .atomic) }
        }
        return .init(exitCode: 0, combinedOutput: "")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

@Test func onlyCurrentSessionStatusIdentifiesAConnectedProcess() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-status-\(UUID().uuidString)", isDirectory: true)
    let recorder = DeviceCommandRecorder()
    let context = deviceContext()
    let bridge = PhysicalDeviceBridge(context: context, workDirectory: root,
                                      runner: recorder.run)
    try bridge.writeSession(token: "current", buildIdentity: context.identity,
                            buildUUIDs: ["uuid"])

    recorder.status = try JSONEncoder().encode(TestDeviceStatus(
        protocolVersion: SpliceProtocol.version, token: "old",
        buildIdentity: context.identity, processId: 10,
        loadedGenerations: [], buildMatchesProcess: true))
    #expect(bridge.connectedProcess() == nil)

    recorder.status = try JSONEncoder().encode(TestDeviceStatus(
        protocolVersion: SpliceProtocol.version, token: "current",
        buildIdentity: context.identity, processId: 11,
        loadedGenerations: [], buildMatchesProcess: true))
    #expect(bridge.connectedProcess() == 11)
}

private func deviceContext(signingIdentity: String? = "SIGNING") -> BuildContext {
    BuildContext(moduleName: "App", swiftCompilerPath: "/swiftc", swiftCompilerVersion: "6",
                 targetTriple: "arm64-apple-ios16.0", sdkPath: "/sdk", sdkName: "iphoneos",
                 appBinaryPath: "/tmp/App.app/App", moduleSearchPaths: [],
                 extraCompilerFlags: [], sourceRoots: [], bundleIdentifier: "dev.example.App",
                 debugDylibPath: "/tmp/App.app/App.debug.dylib",
                 deviceIdentifier: "DEVICE-ID", codeSigningIdentity: signingIdentity)
}

@Test func physicalDeviceBridgeSignsTransfersAndReadsTheRuntimeReply() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("Patch_001.dylib")
    try Data("image".utf8).write(to: image)

    let recorder = DeviceCommandRecorder()
    let bridge = PhysicalDeviceBridge(context: deviceContext(), workDirectory: root,
                                      runner: recorder.run)
    try bridge.writeSession(token: "token", buildIdentity: "identity", buildUUIDs: ["uuid"])
    let delivered = try bridge.deliver(image)
    let request = LoadPatchRequest(generation: 1, path: delivered.path,
                                   buildIdentity: "identity", buildUUIDs: ["uuid"],
                                   declarations: ["Cart.discountLabel()"])
    let reply = try await bridge.requestLoad(request)

    guard case .loaded(let generation, _, let registered, let refreshed) = reply.result else {
        Issue.record("expected a loaded response")
        return
    }
    #expect(generation == 1)
    #expect(registered == 1)
    #expect(refreshed == "layout")
    #expect(reply.processId == 42)
    #expect(recorder.requestToken == "token")

    let calls = recorder.calls
    #expect(calls.contains { $0.0 == "/usr/bin/codesign" && $0.1.first == "--force" })
    #expect(calls.contains { $0.1.contains("Documents/Patches") })
    #expect(calls.contains { $0.1.contains("Documents/SpliceRequests") })
    #expect(calls.contains { $0.1.contains(where: { $0.hasPrefix("Documents/SpliceResponses/") }) })
    #expect(calls.filter { $0.0 == "/usr/bin/xcrun" }.allSatisfy {
        $0.1.contains("DEVICE-ID") && $0.1.contains("dev.example.App")
    })
}

@Test func aPatchSignedByAnotherTeamIsNeverTransferred() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-team-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("Patch_001.dylib")
    try Data("image".utf8).write(to: image)

    let recorder = DeviceCommandRecorder()
    recorder.patchTeam = "OTHER"
    let bridge = PhysicalDeviceBridge(context: deviceContext(), workDirectory: root,
                                      runner: recorder.run)
    do {
        _ = try bridge.deliver(image)
        Issue.record("a mismatched TeamIdentifier should be rejected")
    } catch let error as SpliceError {
        #expect(error.stage == .link)
        #expect(error.reason.contains("OTHER"))
    }
    #expect(!recorder.calls.contains { $0.0 == "/usr/bin/xcrun" })
}

@Test func aMissingSigningIdentityFailsBeforeCodesign() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("device-signing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("Patch_001.dylib")
    try Data("image".utf8).write(to: image)

    let recorder = DeviceCommandRecorder()
    let bridge = PhysicalDeviceBridge(context: deviceContext(signingIdentity: nil),
                                      workDirectory: root, runner: recorder.run)
    #expect(throws: SpliceError.self) { _ = try bridge.deliver(image) }
    #expect(recorder.calls.isEmpty)
}
