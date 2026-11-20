import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import EmberDaemon

/// One live publisher per Simulator app, even if reinstalling the app replaces
/// its data container. The named local message port follows the watcher process
/// and lets a contender retrieve the owner's details before publishing.
final class SimulatorOwnership: @unchecked Sendable {
    struct Owner: Codable, Sendable {
        let pid: Int32
        let emberRoot: String?
        let log: String?
    }

    struct Conflict: Error, CustomStringConvertible {
        let simulator: String
        let bundle: String
        let owner: Owner?

        var description: String {
            guard let owner else {
                return "cannot claim Simulator \(simulator) for \(bundle). Another swift-ember watcher owns it, but its details could not be read."
            }
            var lines = ["Simulator \(simulator) and bundle ID \(bundle) are already in use by swift-ember watcher pid \(owner.pid)."]
            if let root = owner.emberRoot { lines.append("owner .ember       \(root)") }
            if let log = owner.log { lines.append("owner log          \(log)") }
            lines.append("Stop that watcher from its project or select another Simulator with --simulator.")
            return lines.joined(separator: "\n")
        }
    }

    private let port: CFMessagePort?
    /// Set when the claim could not be registered, for example because a
    /// sandbox denies local message ports. The watcher still starts, as it
    /// did before ownership existed, but it cannot detect a second owner.
    let warning: String?

    private init(port: CFMessagePort?, warning: String? = nil) {
        self.port = port
        self.warning = warning
    }
    deinit { if let port { CFMessagePortInvalidate(port) } }

    static func acquire(simulator: String, bundle: String, owner: Owner) throws -> SimulatorOwnership {
        let key = "\(getuid())|\(simulator.uppercased())|\(bundle)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = "dev.swift-ember.simulator.\(digest)" as CFString
        let reply = try JSONEncoder().encode(owner) as NSData
        var context = CFMessagePortContext()
        context.info = Unmanaged.passUnretained(reply).toOpaque()
        context.retain = { info in
            guard let info else { return nil }
            _ = Unmanaged<NSData>.fromOpaque(info).retain()
            return info
        }
        context.release = { info in
            if let info { Unmanaged<NSData>.fromOpaque(info).release() }
        }
        var reused = DarwinBoolean(false)
        let local = withExtendedLifetime(reply) {
            CFMessagePortCreateLocal(nil, name, { _, _, _, info in
                guard let info else { return nil }
                let payload = Unmanaged<NSData>.fromOpaque(info).takeUnretainedValue() as CFData
                return Unmanaged.passRetained(payload)
            }, &context, &reused)
        }
        guard let local, !reused.boolValue else {
            // A contender in the same process gets back the existing port.
            // One in another process gets nil, and finds the owner remotely.
            guard let existing = CFMessagePortCreateRemote(nil, name) else {
                // Nobody owns the name, so registration itself was refused.
                return SimulatorOwnership(port: nil, warning: """
                    warning: cannot register ownership of Simulator \(simulator) for \(bundle). \
                    Another watcher on the same Simulator and bundle ID will not be detected. \
                    Check whether a sandbox denies local message ports.
                    """)
            }
            var response: Unmanaged<CFData>?
            CFMessagePortSendRequest(existing, 0, nil, 1, 1, CFRunLoopMode.defaultMode.rawValue, &response)
            let current = response.flatMap {
                try? JSONDecoder().decode(Owner.self, from: $0.takeRetainedValue() as Data)
            }
            throw Conflict(simulator: simulator, bundle: bundle, owner: current)
        }
        CFMessagePortSetDispatchQueue(local, DispatchQueue.global())
        return SimulatorOwnership(port: local)
    }

    /// Older watchers did not claim a message port. Check the listener named
    /// by the existing session file so a CLI upgrade can preserve its owner.
    static func previousOwner(at session: URL) -> Owner? {
        struct Session: Decodable { let port: UInt16; let token: UUID }
        guard let values = try? session.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate,
              let data = try? Data(contentsOf: session),
              let saved = try? JSONDecoder().decode(Session.self, from: data),
              saved.port != 0,
              let result = try? Subprocess.runSeparated("/usr/sbin/lsof", arguments: [
                "-nP", "-a", "-i4TCP@127.0.0.1:\(saved.port)", "-sTCP:LISTEN", "-Fp",
              ]), result.exitCode == 0
        else { return nil }
        for line in result.standardOutput.split(separator: "\n") where line.hasPrefix("p") {
            guard let pid = Int32(line.dropFirst()), pid != getpid(),
                  let identity = Lifecycle.processIdentity(pid),
                  Double(identity.startedAtMicroseconds) / 1_000_000 <= modifiedAt.timeIntervalSince1970,
                  ["swift-ember", "swift-splice"].contains(URL(fileURLWithPath: identity.executablePath).lastPathComponent)
            else { continue }
            let log = processLog(pid)
            return Owner(pid: pid, emberRoot: log?.deletingLastPathComponent().deletingLastPathComponent().path,
                         log: log?.path)
        }
        return nil
    }

    private static func processLog(_ pid: Int32) -> URL? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidfdinfo(pid, STDOUT_FILENO, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let log = URL(fileURLWithPath: path)
        let parent = log.deletingLastPathComponent()
        guard parent.lastPathComponent == "logs", parent.deletingLastPathComponent().lastPathComponent == ".ember"
        else { return nil }
        return log
    }
}
