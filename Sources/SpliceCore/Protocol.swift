import Foundation

/// The versioned wire protocol from DESIGN.md section 11.2.
///
/// One JSON object per line over a loopback socket. Newline framing keeps the
/// traffic readable with `nc`, which section 11.1 asks for explicitly: the MVP
/// should optimise for observability rather than cleverness.
public enum SpliceProtocol {
    public static let version = 1
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
    public var buildIdentity: String
    public var moduleName: String
    public var processId: Int32
    public var loadedGenerations: [UInt64]

    public init(buildIdentity: String, moduleName: String, processId: Int32, loadedGenerations: [UInt64]) {
        self.buildIdentity = buildIdentity
        self.moduleName = moduleName
        self.processId = processId
        self.loadedGenerations = loadedGenerations
    }
}

/// daemon -> runtime. The image travels as a file path rather than as bytes:
/// the daemon can already write into the application's container, and a path
/// keeps the artifact inspectable after the fact.
public struct LoadPatchRequest: Codable, Sendable {
    public var generation: UInt64
    public var path: String
    public var buildIdentity: String
    public var declarations: [String]

    public init(generation: UInt64, path: String, buildIdentity: String, declarations: [String]) {
        self.generation = generation
        self.path = path
        self.buildIdentity = buildIdentity
        self.declarations = declarations
    }
}

/// runtime -> daemon.
public enum LoadPatchResult: Codable, Sendable {
    case loaded(generation: UInt64, durationMs: Double)
    case rejected(reason: String)
    case failed(stage: Stage, message: String)
}
