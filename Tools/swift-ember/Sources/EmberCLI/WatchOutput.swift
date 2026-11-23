import Foundation
import EmberCore
import EmberDaemon

struct ReloadReport: Encodable {
    struct Registration: Encodable {
        let counted: Int
        let expected: Int
    }

    struct OneShot: Encodable {
        enum Scope: String, Encodable {
            case instance, process
        }

        let name: String
        let scope: Scope
    }

    let generation: UInt64
    let declarations: [String]
    let carried: [String]
    let verified: Bool
    let registered: Registration?
    let refreshed: String?
    let oneShot: [OneShot]
    let timings: [StageEvent]
    let totalMs: Double

    init(
        generation: UInt64, declarations: [String], carried: [String], verified: Bool,
        registered: (counted: Int, expected: Int)?, refreshed: String?,
        oneShot: [OneShotNote], timeline: StageTimeline
    ) {
        self.generation = generation
        self.declarations = declarations
        self.carried = carried
        self.verified = verified
        self.registered = registered.map { Registration(counted: $0.counted, expected: $0.expected) }
        self.refreshed = refreshed
        self.oneShot = oneShot.map { OneShot(name: $0.name, scope: $0.scope == .instance ? .instance : .process) }
        timings = timeline.all
        totalMs = timings.reduce(0) { $0 + $1.durationMs }
    }

    private enum Key: String, CodingKey {
        case generation, declarations, carried, verified, registered, refreshed, oneShot, timings, totalMs
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(generation, forKey: .generation)
        try fields.encode(declarations, forKey: .declarations)
        try fields.encode(carried, forKey: .carried)
        try fields.encode(verified, forKey: .verified)
        try fields.encode(registered, forKey: .registered)
        try fields.encode(refreshed, forKey: .refreshed)
        try fields.encode(oneShot, forKey: .oneShot)
        try fields.encode(timings, forKey: .timings)
        try fields.encode(totalMs, forKey: .totalMs)
    }

    func runtimeMessage() -> RuntimeLogMessage {
        let count = declarations.count
        let noun = count == 1 ? "declaration" : "declarations"
        var lines = [String(format: "hot reloaded %d %@ in %.0f ms  (g%llu)",
                                   count, noun, totalMs, generation)]
        for name in declarations {
            let line = "  \(name)"
            lines.append(line)
        }
        // Named rather than counted. A carried declaration is one
        // the patch had to bring with it -- a private helper, or one
        // that did not exist in the build -- and seeing which is the
        // difference between "that is why it worked" and a mystery.
        if !carried.isEmpty {
            let line = "  carried: \(carried.joined(separator: ", "))"
            lines.append(line)
        }
        // Said only when it is not true. A reload that could not be
        // confirmed is still a reload, but the developer should know
        // which kind they are looking at. A reload nobody can
        // vouch for is the shape this project refuses elsewhere,
        // and saying so is what keeps it from being one.
        if !verified {
            // Which way the count was wrong, not only that it was.
            // "Could not count" and "counted more than were asked
            // for" are different problems and were reported with
            // the same sentence.
            if let registered {
                // "Contributed", not "declared": for an `@objc`
                // member the evidence is an Objective-C category,
                // which says the image brought a method and not
                // that it replaced one.
                // Always plural: a count below the expected one
                // ends the session before it reaches here, and the
                // expected count is never zero, so the smallest
                // number this line can carry is two.
                // Records, not declarations: an accessor and an
                // opaque return each bring one, so the two numbers
                // are not counts of the same thing and saying
                // "declarations" made a correct pair look wrong.
                let plural = registered.expected == 1 ? "was" : "were"
                let line = "  not verified: the image carries \(registered.counted) replacement "
                    + "records and \(registered.expected) \(plural) generated"
                lines.append(line)
            } else {
                let line = "  not verified: the runtime could not read the image's records"
                lines.append(line)
            }
        }
        // What it took to put the change on screen. A UIKit process
        // is told to lay out again, and a list to reload; without
        // that the body is replaced in the process and the screen
        // keeps whatever it drew last.
        if let refreshed {
            let line = "  refreshed: \(refreshed)"
            lines.append(line)
        }
        // The entry points a refresh cannot reach on its own. Said
        // rather than left to be discovered: an edit that loads and
        // changes nothing is the outcome this tool exists to avoid
        // reporting as success.
        // Grouped by how far out of reach the new body is. A view
        // controller can be made again inside this process and will
        // run it; an application delegate cannot, and a relaunch
        // starts from the built binary with no patch in it -- so
        // telling someone to make another one would be advice that
        // does not work.
        let reachable = oneShot.filter { $0.scope == .instance }
        let unreachable = oneShot.filter { $0.scope == .process }
        if !reachable.isEmpty {
            let notes = [
                "  already ran: \(reachable.map(\.name).joined(separator: ", "))",
                "  replaced, but UIKit will not call it again for anything that",
                "  already exists; the next instance of that type runs the new body",
            ]
            lines.append(contentsOf: notes)
        }
        if !unreachable.isEmpty {
            let notes = [
                "  already ran: \(unreachable.map(\.name).joined(separator: ", "))",
                "  there is one of these per process, and relaunching starts from the",
                "  built binary, so seeing this change takes a build",
            ]
            lines.append(contentsOf: notes)
        }
        let hasCaveat = !verified || !oneShot.isEmpty
        return RuntimeLogMessage(level: hasCaveat ? .warning : .success, message: lines.joined(separator: "\n"))
    }
}

enum WatchEvent {
    case started(sourceRoots: [String], buildOutputPaths: [String], port: UInt16, simulator: String?, device: String?)
    case connected(processId: Int32, bundleIdentifier: String)
    case connectionRefused(processId: Int32?, message: String)
    case disconnected
    case reloaded(ReloadReport)
    case rebuildRequired(EmberError)
    case error(EmberError)
    case sessionUncertain(EmberError)
    case warning(String)
    case rebuildStarted(directory: String)
    case rebuildCompleted(processId: Int32)
    case rebuildFailed(String)
    case stopped

    static func rejection(_ error: EmberError) -> Self {
        error.recovery == .rebuild ? .rebuildRequired(error) : .error(error)
    }
}

private struct WatchLine: Encodable {
    let event: WatchEvent
    let seq: UInt64
    let at: Date

    private enum Key: String, CodingKey {
        case v, type, seq, at
        case sourceRoots, buildOutputPaths, port, simulator, device
        case processId, bundleIdentifier, message, directory
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(CLIJSON.version, forKey: .v)
        try fields.encode(seq, forKey: .seq)
        try fields.encode(at, forKey: .at)
        let type: String
        switch event {
        case .started(let sourceRoots, let buildOutputPaths, let port, let simulator, let device):
            type = "started"
            try fields.encode(sourceRoots, forKey: .sourceRoots)
            try fields.encode(buildOutputPaths, forKey: .buildOutputPaths)
            try fields.encode(port, forKey: .port)
            try fields.encodeIfPresent(simulator, forKey: .simulator)
            try fields.encodeIfPresent(device, forKey: .device)
        case .connected(let processId, let bundleIdentifier):
            type = "connected"
            try fields.encode(processId, forKey: .processId)
            try fields.encode(bundleIdentifier, forKey: .bundleIdentifier)
        case .connectionRefused(let processId, let message):
            type = "connection_refused"
            try fields.encodeIfPresent(processId, forKey: .processId)
            try fields.encode(message, forKey: .message)
        case .disconnected:
            type = "disconnected"
        case .reloaded(let report):
            type = "reloaded"
            try report.encode(to: encoder)
        case .rebuildRequired(let error):
            type = "rebuild_required"
            try error.encode(to: encoder)
        case .error(let error):
            type = "error"
            try error.encode(to: encoder)
        case .sessionUncertain(let error):
            type = "session_uncertain"
            try error.encode(to: encoder)
        case .warning(let message):
            type = "warning"
            try fields.encode(message, forKey: .message)
        case .rebuildStarted(let directory):
            type = "rebuild_started"
            try fields.encode(directory, forKey: .directory)
        case .rebuildCompleted(let processId):
            type = "rebuild_completed"
            try fields.encode(processId, forKey: .processId)
        case .rebuildFailed(let message):
            type = "rebuild_failed"
            try fields.encode(message, forKey: .message)
        case .stopped:
            type = "stopped"
        }
        try fields.encode(type, forKey: .type)
    }
}

final class WatchOutput: @unchecked Sendable {
    let json: Bool
    private let writeLine: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var stopped = false

    init(json: Bool, writeLine: @escaping @Sendable (Data) -> Void = CLIJSON.writeToStdout) {
        self.json = json
        self.writeLine = writeLine
    }

    func report(_ event: @autoclosure () -> WatchEvent, human: () -> Void = {}) {
        guard json else {
            human()
            return
        }
        lock.withLock {
            guard !stopped else { return }
            write(event())
        }
    }

    func warning(_ message: String) {
        report(.warning(message)) { print(message) }
    }

    func reportReload(
        _ reload: ReloadReport, summary: @autoclosure () -> String,
        printLine: (String) -> Void = { print($0) }
    ) -> RuntimeLogMessage {
        let message = reload.runtimeMessage()
        report(.reloaded(reload)) {
            printLine("")
            printLine(message.message)
            printLine(summary())
            printLine("")
        }
        return message
    }

    func finish() {
        guard json else { return }
        lock.withLock {
            guard !stopped else { return }
            write(.stopped)
            stopped = true
        }
    }

    private func write(_ event: WatchEvent) {
        sequence += 1
        CLIJSON.write(WatchLine(event: event, seq: sequence, at: Date()), to: writeLine)
    }
}
