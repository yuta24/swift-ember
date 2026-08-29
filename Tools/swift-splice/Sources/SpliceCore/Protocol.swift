import Foundation

/// The versioned wire protocol from DESIGN.md section 11.2.
///
/// One JSON object per line over a loopback socket. Newline framing keeps the
/// traffic readable with `nc`, which section 11.1 asks for explicitly: the MVP
/// should optimise for observability rather than cleverness.
public enum SpliceProtocol {
    /// Bumped when a payload's shape changes. Version 2 added the build
    /// UUIDs, without which the runtime's identity check compared the
    /// daemon's own string against the daemon's own string. Version 3 added
    /// the count of replacements the loaded image registered, which is what
    /// FR-13 rests on. Version 4 added the session token to the handshake,
    /// which until then was generated, written into the session file, and
    /// never looked at by either side. Version 5 added what the runtime did to
    /// make the generation visible, which for a UIKit application is the
    /// difference between a loaded patch and a changed screen. Version 6 added
    /// expiring requests and process-bearing replies for physical devices.
    public static let version = 6
    public static let defaultPort: UInt16 = 51_237
}

public struct Envelope: Codable, Sendable {
    public var protocolVersion: Int
    public var type: String
    public var requestId: String
    public var payload: Data

    public init<P: Codable>(type: String, requestId: String = UUID().uuidString, payload: P) throws {
        self.protocolVersion = SpliceProtocol.version
        self.type = type
        self.requestId = requestId
        self.payload = try JSONEncoder().encode(payload)
    }

    /// For a payload that is already encoded, such as one being relayed or
    /// constructed by a test.
    public init(type: String, requestId: String = UUID().uuidString, rawPayload: Data) {
        self.protocolVersion = SpliceProtocol.version
        self.type = type
        self.requestId = requestId
        self.payload = rawPayload
    }

    public func decode<P: Codable>(_ type: P.Type) throws -> P {
        try JSONDecoder().decode(P.self, from: payload)
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

/// runtime -> daemon, once per connection.
public struct Hello: Codable, Sendable {
    /// The token from the session file, which the daemon wrote into this app's
    /// own container.
    ///
    /// It proves the connection came from something that can read that
    /// container, which a process dialling a loopback port blindly cannot. That
    /// is the case worth closing: without it, anything that connected could
    /// answer for the app, and the tool would report reloads that never reached
    /// the process.
    ///
    /// It is not a secret. The session file is world-readable to the developer's
    /// own processes, so anything determined enough to look can present it. The
    /// threat model is a local mistake --- another `watch`, a stray tool, a port
    /// scan --- not an adversary on the same machine.
    public var token: String
    public var buildIdentity: String
    public var moduleName: String
    public var processId: Int32
    public var loadedGenerations: [UInt64]
    /// Whether the process found one of the daemon's build UUIDs among its own
    /// loaded images.
    ///
    /// The runtime's verdict, not the daemon's. Everything else here is a
    /// string the daemon wrote into the session file and the runtime read back,
    /// which says nothing about the process it is in.
    public var buildMatchesProcess: Bool

    public init(token: String, buildIdentity: String, moduleName: String, processId: Int32,
                loadedGenerations: [UInt64], buildMatchesProcess: Bool) {
        self.token = token
        self.buildIdentity = buildIdentity
        self.moduleName = moduleName
        self.processId = processId
        self.loadedGenerations = loadedGenerations
        self.buildMatchesProcess = buildMatchesProcess
    }
}

/// daemon -> runtime. The image travels as a file path rather than as bytes:
/// the daemon can already write into the application's container, and a path
/// keeps the artifact inspectable after the fact.
public struct LoadPatchRequest: Codable, Sendable {
    public var generation: UInt64
    public var path: String
    public var buildIdentity: String
    /// The link target's UUIDs, one per architecture slice. The runtime refuses
    /// a patch when it is running none of them.
    public var buildUUIDs: [String]
    public var declarations: [String]

    public init(generation: UInt64, path: String, buildIdentity: String,
                buildUUIDs: [String], declarations: [String]) {
        self.generation = generation
        self.path = path
        self.buildIdentity = buildIdentity
        self.buildUUIDs = buildUUIDs
        self.declarations = declarations
    }
}

/// runtime -> daemon.
public enum LoadPatchResult: Codable, Sendable {
    /// `registered` is how many dynamic replacements the loaded image declared,
    /// or nil when the runtime could not examine it. The daemon compares it
    /// against what it asked for: `dlopen` returning a handle says the image
    /// mapped, not that anything in it was bound.
    /// `refreshed` is what the runtime's UIKit adapter touched, or nil when
    /// there was nothing to touch -- no window yet, no UIKit, or the
    /// application turned the refresh off.
    case loaded(generation: UInt64, durationMs: Double, registered: Int?, refreshed: String?)
    case rejected(reason: String)
    case failed(stage: Stage, message: String)
}
