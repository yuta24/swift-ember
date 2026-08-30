#if EMBER_ENABLED && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)

import Foundation

/// Physical-device transport for the in-app runtime.
///
/// There is no host loopback socket on an iPhone. CoreDevice copies a request
/// into this application's Documents directory; this client applies it and
/// writes a response that the host copies back. The application must be in a
/// runnable state -- iOS may suspend this queue while it is backgrounded.
final class EmberDeviceClient: @unchecked Sendable {
    /// Requests are serialized by the host, so 32 leaves ample room for the
    /// response currently being copied while preventing a long watch session
    /// from growing the app container without bound. A successfully dlopened
    /// image remains mapped after its directory entry is removed.
    private static let retainedArtifactCount = 32

    // These pre-Ember names are protocol identifiers shared with host tools
    // and already-built runtimes. They change only with an explicit migration.
    private enum TransportPath {
        static let session = "splice-session.json"
        static let status = "splice-device-status.json"
        static let requests = "SpliceRequests"
        static let responses = "SpliceResponses"
    }

    private struct Session: Codable {
        let protocolVersion: Int
        let token: String
        let buildIdentity: String
        let buildUUIDs: [String]
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

    private struct DeviceStatus: Codable {
        let protocolVersion: Int
        let token: String
        let buildIdentity: String
        let processId: Int32
        let loadedGenerations: [UInt64]
        let buildMatchesProcess: Bool
    }

    private let state: Ember.StateBox
    private let applier: RuntimePatchApplier
    private let queue = DispatchQueue(label: "dev.swift-ember.device-runtime")
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var session: Session?
    private var connected = false

    init(state: Ember.StateBox) {
        self.state = state
        self.applier = RuntimePatchApplier(state: state)
    }

    func start() { queue.async { self.tick() } }

    private func tick() {
        refreshSession()
        if session != nil { processRequests() }
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { self.tick() }
    }

    private func refreshSession() {
        let url = documents.appendingPathComponent(TransportPath.session)
        guard let data = try? Data(contentsOf: url),
              let found = try? JSONDecoder().decode(Session.self, from: data),
              found.protocolVersion == ProtocolVersion else {
            setConnected(false)
            session = nil
            return
        }

        if session?.token != found.token {
            session = found
            applier.expect(buildIdentity: found.buildIdentity, buildUUIDs: found.buildUUIDs)
            writeStatus(for: found)
        }
        setConnected(true)
    }

    private func processRequests() {
        let requests = documents.appendingPathComponent(TransportPath.requests, isDirectory: true)
        let responses = documents.appendingPathComponent(TransportPath.responses, isDirectory: true)
        try? FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requests, includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension == "json" {
            let response = responses.appendingPathComponent(file.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: response.path) else { continue }
            handle(file, response: response)
        }

        prune(requests)
        prune(responses)
        prune(documents.appendingPathComponent("Patches", isDirectory: true))
    }

    private func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return }

        let regularFiles = files.filter {
            (try? $0.resourceValues(forKeys: keys).isRegularFile) == true
        }
        guard regularFiles.count > Self.retainedArtifactCount else { return }

        let oldestFirst = regularFiles.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
            return left < right
        }
        for file in oldestFirst.dropLast(Self.retainedArtifactCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func handle(_ file: URL, response: URL) {
        let fallbackID = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            write(.failed(stage: "LOAD", message: "the runtime could not decode the device request"),
                  requestID: fallbackID, to: response)
            return
        }
        guard envelope.protocolVersion == ProtocolVersion else {
            write(.failed(stage: "LOAD",
                          message: "the runtime speaks protocol \(ProtocolVersion) and the daemon speaks \(envelope.protocolVersion); upgrade one side"),
                  requestID: envelope.requestId, to: response)
            return
        }
        guard envelope.type == "loadPatch",
              let command = try? envelope.decode(DeviceLoadCommand.self) else {
            write(.failed(stage: "LOAD", message: "the runtime could not decode the load request"),
                  requestID: envelope.requestId, to: response)
            return
        }

        guard command.expiresAt > Date() else {
            write(.failed(stage: "LOAD", message: "the device request expired before the app could apply it"),
                  requestID: envelope.requestId, to: response)
            return
        }

        guard command.token == session?.token else {
            write(.rejected(reason: "the device request belongs to a different watch session"),
                  requestID: envelope.requestId, to: response)
            return
        }

        var request = command.request
        let imageName = URL(fileURLWithPath: request.path).lastPathComponent
        request.path = documents
            .appendingPathComponent("Patches", isDirectory: true)
            .appendingPathComponent(imageName).path
        write(applier.apply(request), requestID: envelope.requestId, to: response)
        if let session { writeStatus(for: session) }
    }

    private func write(_ result: LoadPatchResult, requestID: String, to url: URL) {
        let reply = DeviceLoadReply(result: result,
                                    processId: ProcessInfo.processInfo.processIdentifier)
        guard let payload = try? JSONEncoder().encode(reply) else { return }
        let envelope = Envelope(protocolVersion: ProtocolVersion, type: "loadResult",
                                requestId: requestID, payload: payload)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        state.setConnected(value)
    }

    private func writeStatus(for session: Session) {
        let status = DeviceStatus(
            protocolVersion: ProtocolVersion,
            token: session.token,
            buildIdentity: session.buildIdentity,
            processId: ProcessInfo.processInfo.processIdentifier,
            loadedGenerations: state.generations,
            buildMatchesProcess: LoadedImages.running(oneOf: session.buildUUIDs))
        guard let data = try? JSONEncoder().encode(status) else { return }
        let url = documents.appendingPathComponent(TransportPath.status)
        try? data.write(to: url, options: .atomic)
    }
}

#endif
