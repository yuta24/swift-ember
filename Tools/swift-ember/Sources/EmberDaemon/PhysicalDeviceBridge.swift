import Foundation
import EmberCore

/// The host half of physical-device delivery.
///
/// CoreDevice can copy into an application's data container without exposing
/// its private path. Requests and replies therefore travel as files rather
/// than through the simulator's loopback socket. The image is copied first and
/// the small request file last, so the runtime never observes a partial dylib.
final class PhysicalDeviceBridge: @unchecked Sendable {
    typealias Runner = @Sendable (String, [String]) throws -> Subprocess.Result

    // These pre-Ember names are protocol identifiers shared with already-built
    // runtimes. Keep them stable until a protocol-version migration handles
    // both spellings explicitly.
    private enum TransportPath {
        static let session = "splice-session.json"
        static let status = "splice-device-status.json"
        static let requests = "SpliceRequests"
        static let responses = "SpliceResponses"
    }

    private let context: BuildContext
    private let deviceIdentifier: String
    private let workDirectory: URL
    private let runner: Runner
    private let lock = NSLock()
    /// Console delivery is observability, not part of the patch transaction.
    /// Keep CoreDevice's synchronous subprocess off the coordinator actor and
    /// serialize messages. While one transfer is active, only the newest
    /// pending result is retained so Xcode is not fed a stale backlog.
    private let runtimeLogQueue = DispatchQueue(label: "dev.swift-ember.device-runtime-log")
    private var sessionToken = ""
    private var pendingRuntimeLog: QueuedRuntimeLog?
    private var runtimeLogDeliveryActive = false

    private struct QueuedRuntimeLog: Sendable {
        let token: String
        let log: RuntimeLogMessage
        let expiresAt: Date
    }

    private struct DeviceLoadCommand: Codable {
        let token: String
        let request: LoadPatchRequest
        let expiresAt: Date
    }

    private struct DeviceLoadReply: Codable {
        let result: LoadPatchResult
        let processId: Int32
    }

    private struct DeviceRuntimeLogCommand: Codable {
        let token: String
        let log: RuntimeLogMessage
        let expiresAt: Date
    }

    private struct DeviceStatus: Codable {
        let protocolVersion: Int
        let token: String
        let buildIdentity: String
        let processId: Int32
        let loadedGenerations: [UInt64]
        let buildMatchesProcess: Bool
    }

    struct Reply: Sendable {
        let result: LoadPatchResult
        let processId: Int32
    }

    init(context: BuildContext, workDirectory: URL,
         runner: @escaping Runner = { try Subprocess.run($0, arguments: $1) }) {
        precondition(context.deviceIdentifier != nil)
        self.context = context
        self.deviceIdentifier = context.deviceIdentifier!
        self.workDirectory = workDirectory.appendingPathComponent("device", isDirectory: true)
        self.runner = runner
    }

    func writeSession(token: String, buildIdentity: String, buildUUIDs: [String]) throws {
        struct Session: Codable {
            let protocolVersion: Int
            let token: String
            let buildIdentity: String
            let buildUUIDs: [String]
        }

        lock.withLock { sessionToken = token }
        let session = Session(protocolVersion: EmberProtocol.version, token: token,
                              buildIdentity: buildIdentity, buildUUIDs: buildUUIDs)
        let local = workDirectory.appendingPathComponent(TransportPath.session)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try JSONEncoder.sorted.encode(session).write(to: local, options: .atomic)
        try copyToDevice(source: local, destination: "Documents/\(TransportPath.session)")
    }

    /// Returns a process only when the status belongs to this watch session
    /// and the process has proved it loaded the binary on disk. A new PID is
    /// what clears a poisoned session after the developer relaunches the app.
    func connectedProcess() -> Int32? {
        let local = workDirectory
            .appendingPathComponent("status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: local) }
        guard let result = try? runner("/usr/bin/xcrun", copyFromArguments(
            source: "Documents/\(TransportPath.status)", destination: local.path)),
              result.exitCode == 0,
              let data = try? Data(contentsOf: local),
              let status = try? JSONDecoder().decode(DeviceStatus.self, from: data),
              status.protocolVersion == EmberProtocol.version,
              status.token == lock.withLock({ sessionToken }),
              status.buildIdentity == context.identity,
              status.buildMatchesProcess else { return nil }
        return status.processId
    }

    func deliver(_ image: URL) throws -> URL {
        try signAndVerify(image)

        // A watch restart begins at g1 again while the app may still be the
        // same process. dyld keys loaded images by path, so reusing
        // Patch_001.dylib would return the old handle and report a reload that
        // changed nothing. The daemon's session token makes the device path
        // unique without changing the inspectable local artifact name.
        let token = lock.withLock { sessionToken }
        let remoteName = "\(token.prefix(8))-\(UUID().uuidString)-\(image.lastPathComponent)"

        let stagingRoot = workDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let staging = stagingRoot
            .appendingPathComponent("Patches", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(remoteName)
        try FileManager.default.copyItem(at: image, to: staged)
        try copyToDevice(source: staging, destination: "Documents/Patches")
        return URL(fileURLWithPath: "Documents/Patches/\(remoteName)")
    }

    func requestLoad(_ request: LoadPatchRequest) async throws -> Reply {
        let requestID = UUID().uuidString
        let command = DeviceLoadCommand(token: lock.withLock { sessionToken }, request: request,
                                        expiresAt: Date().addingTimeInterval(9.5))
        let envelope = try Envelope(type: "loadPatch", requestId: requestID, payload: command)
        let stagingRoot = workDirectory
            .appendingPathComponent("request-\(requestID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let staging = stagingRoot
            .appendingPathComponent(TransportPath.requests, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let requestFile = staging.appendingPathComponent("\(requestID).json")
        try JSONEncoder.sorted.encode(envelope).write(to: requestFile, options: .atomic)
        try copyToDevice(source: staging, destination: "Documents/\(TransportPath.requests)")

        let response = workDirectory.appendingPathComponent("response-\(requestID).json")
        defer { try? FileManager.default.removeItem(at: response) }
        var lastOutput = "the device did not write a response"
        for _ in 0..<40 {
            let result = try runner("/usr/bin/xcrun", copyFromArguments(
                source: "Documents/\(TransportPath.responses)/\(requestID).json",
                destination: response.path))
            if result.exitCode == 0,
               let data = try? Data(contentsOf: response),
               let reply = try? JSONDecoder().decode(Envelope.self, from: data) {
                guard reply.protocolVersion == EmberProtocol.version else {
                    throw EmberError(stage: .load, subject: requestFile.lastPathComponent,
                                      reason: "the runtime speaks protocol \(reply.protocolVersion) and the daemon speaks \(EmberProtocol.version)",
                                      recovery: .rebuild)
                }
                guard reply.requestId == requestID, reply.type == "loadResult" else {
                    throw EmberError(stage: .load, subject: requestFile.lastPathComponent,
                                      reason: "the device returned a response for a different request",
                                      recovery: .restart)
                }
                let deviceReply = try reply.decode(DeviceLoadReply.self)
                return Reply(result: deviceReply.result, processId: deviceReply.processId)
            }
            if !result.combinedOutput.isEmpty { lastOutput = result.combinedOutput }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw EmberError(stage: .load, subject: requestFile.lastPathComponent,
                          reason: "the physical device did not answer within 10 seconds: \(lastOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                          recovery: .restart)
    }

    /// Copies a console message to the app without waiting for a response.
    /// The runtime leaves a receipt file solely to avoid processing the same
    /// request on every polling tick; delivery remains best-effort to the host.
    func sendRuntimeLog(_ log: RuntimeLogMessage) {
        let startDelivery = lock.withLock { () -> Bool in
            // Snapshot both the token and the expiry at enqueue time. A later
            // session must not relabel this message, and a delayed diagnostic
            // must not become fresh merely because CoreDevice was slow.
            pendingRuntimeLog = QueuedRuntimeLog(
                token: sessionToken, log: log,
                expiresAt: Date().addingTimeInterval(9.5))
            guard !runtimeLogDeliveryActive else { return false }
            runtimeLogDeliveryActive = true
            return true
        }
        guard startDelivery else { return }
        runtimeLogQueue.async { [self] in drainRuntimeLogs() }
    }

    private func drainRuntimeLogs() {
        while let queued = lock.withLock({ () -> QueuedRuntimeLog? in
            guard let queued = pendingRuntimeLog else {
                runtimeLogDeliveryActive = false
                return nil
            }
            pendingRuntimeLog = nil
            return queued
        }) {
            guard queued.expiresAt > Date() else { continue }
            let requestID = UUID().uuidString
            let command = DeviceRuntimeLogCommand(
                token: queued.token, log: queued.log, expiresAt: queued.expiresAt)
            guard let envelope = try? Envelope(
                type: "runtimeLog", requestId: requestID, payload: command) else { continue }
            let stagingRoot = workDirectory
                .appendingPathComponent("log-\(requestID)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let staging = stagingRoot
                .appendingPathComponent(TransportPath.requests, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true)
                let requestFile = staging.appendingPathComponent("\(requestID).json")
                try JSONEncoder.sorted.encode(envelope)
                    .write(to: requestFile, options: .atomic)
                try copyToDevice(source: staging,
                                 destination: "Documents/\(TransportPath.requests)")
            } catch {
                // The daemon log remains canonical. Console delivery never
                // changes a patch outcome or the session's uncertainty state.
            }
        }
    }

    private func signAndVerify(_ image: URL) throws {
        guard let identity = context.codeSigningIdentity, !identity.isEmpty else {
            throw EmberError(stage: .link, subject: image.lastPathComponent,
                              reason: "the physical-device build did not report a signing identity; configure Development signing or pass --signing-identity",
                              recovery: .configure)
        }

        let appTeam = try teamIdentifier(of: context.linkTarget)
        let signed = try runner("/usr/bin/codesign", ["--force", "--sign", identity,
                                                       "--timestamp=none", image.path])
        guard signed.exitCode == 0 else {
            throw EmberError(stage: .link, subject: image.lastPathComponent,
                              reason: "codesign failed: \(signed.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                              recovery: .configure)
        }
        let patchTeam = try teamIdentifier(of: image.path)
        guard patchTeam == appTeam else {
            throw EmberError(stage: .link, subject: image.lastPathComponent,
                              reason: "the patch was signed by Team \(patchTeam), but the app was signed by Team \(appTeam)",
                              recovery: .configure)
        }
    }

    private func teamIdentifier(of path: String) throws -> String {
        let result = try runner("/usr/bin/codesign", ["-d", "--verbose=4", path])
        guard result.exitCode == 0 else {
            throw EmberError(stage: .link, subject: (path as NSString).lastPathComponent,
                              reason: "could not inspect the code signature: \(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                              recovery: .configure)
        }
        guard let line = result.combinedOutput.split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw EmberError(stage: .link, subject: (path as NSString).lastPathComponent,
                              reason: "the code signature has no TeamIdentifier",
                              recovery: .configure)
        }
        return String(line.dropFirst("TeamIdentifier=".count))
    }

    private func copyToDevice(source: URL, destination: String) throws {
        let result = try runner("/usr/bin/xcrun", copyToArguments(source: source.path,
                                                                    destination: destination))
        guard result.exitCode == 0 else {
            throw EmberError(stage: .transfer, subject: source.lastPathComponent,
                              reason: "devicectl could not copy to the physical device: \(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                              recovery: .restart)
        }
    }

    func copyToArguments(source: String, destination: String) -> [String] {
        ["devicectl", "device", "copy", "to",
         "--device", deviceIdentifier,
         "--domain-type", "appDataContainer",
         "--domain-identifier", context.bundleIdentifier,
         "--source", source, "--destination", destination]
    }

    func copyFromArguments(source: String, destination: String) -> [String] {
        ["devicectl", "device", "copy", "from",
         "--device", deviceIdentifier,
         "--domain-type", "appDataContainer",
         "--domain-identifier", context.bundleIdentifier,
         "--source", source, "--destination", destination]
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
