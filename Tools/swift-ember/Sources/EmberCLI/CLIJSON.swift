@preconcurrency import Darwin
import Foundation
import EmberCore

enum CLIJSON {
    static let version = 1

    static func writeToStdout(_ line: Data) { writeLine(line, to: stdout) }

    private static func writeLine(_ line: Data, to stream: UnsafeMutablePointer<FILE>) {
        // Match print's stdio behavior for a closed or nonblocking stream.
        // Write the complete line together and flush before returning.
        line.withUnsafeBytes { bytes in
            _ = fwrite(bytes.baseAddress, 1, bytes.count, stream)
        }
        _ = fflush(stream)
    }

    static func write(
        _ value: some Encodable, to output: @Sendable (Data) -> Void = writeToStdout
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var line = try encoder.encode(value)
            line.append(0x0a)
            output(line)
        } catch {
            writeLine(Data("cannot encode CLI JSON: \(error)\n".utf8), to: stderr)
        }
    }
}

struct StartDocument: Encodable {
    enum Kind: String, Encodable {
        case started
        case alreadyRunning = "already_running"
    }

    let v = CLIJSON.version
    let type: Kind
    let pid: Int32
    let log: String
    let simulator: String?
    let warning: String?
}

struct StatusDocument: Encodable {
    struct Daemon: Encodable {
        let running: Bool
        let pid: Int32?
        let simulator: String?
        let warning: String?
    }

    struct SessionPaths: Encodable {
        let record: String
        let context: String
        let log: String
        let patches: String
        let lock: String

        init(_ session: Lifecycle.Session) {
            record = session.recordURL.path
            context = session.contextURL.path
            log = session.logURL.path
            patches = session.patchURL.path
            lock = session.lockURL.path
        }
    }

    // This is an allowlist of status fields. BuildContext also contains
    // settings used to sign and load patches.
    struct Context: Encodable {
        let moduleName: String
        let targetTriple: String
        let sdkName: String
        let swiftCompilerVersion: String
        let bundleIdentifier: String
        let deviceIdentifier: String?
        let simulatorIdentifier: String?
        let appBinaryPath: String
        let sourceRoots: [String]
        let excludedSourcePaths: [String]
        let extraCompilerFlags: [String]
        let identity: String

        init(_ context: BuildContext) {
            moduleName = context.moduleName
            targetTriple = context.targetTriple
            sdkName = context.sdkName
            swiftCompilerVersion = context.swiftCompilerVersion
            bundleIdentifier = context.bundleIdentifier
            deviceIdentifier = context.deviceIdentifier
            simulatorIdentifier = context.simulatorIdentifier
            appBinaryPath = context.appBinaryPath
            sourceRoots = context.sourceRoots
            excludedSourcePaths = context.excludedSourcePaths
            extraCompilerFlags = context.extraCompilerFlags
            identity = context.identity
        }
    }

    struct Rebuild: Encodable {
        let command: String?
        let directory: String?
        let timeoutSeconds: TimeInterval
    }

    let v = CLIJSON.version
    let type = "status"
    let daemon: Daemon
    let session: SessionPaths
    let context: Context
    let rebuild: Rebuild

    init(running: Lifecycle.RunningSession?, session: Lifecycle.Session, context: BuildContext, options: Options) {
        daemon = Daemon(running: running != nil, pid: running?.pid,
                        simulator: running?.simulatorIdentifier, warning: running?.simulatorWarning)
        self.session = SessionPaths(session)
        self.context = Context(context)
        let directory = options.rebuildCommand == nil ? nil : options.rebuildDirectory
        rebuild = Rebuild(command: options.rebuildCommand, directory: directory,
                          timeoutSeconds: options.rebuildTimeout)
    }
}
