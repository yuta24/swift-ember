import Foundation

/// The pipeline stages from DESIGN.md section 17. Every diagnostic names one,
/// so a failure says where it happened before it says what happened.
public enum Stage: String, Codable, Sendable, CaseIterable {
    case watch = "WATCH"
    case classify = "CLASSIFY"
    case generate = "GENERATE"
    case compile = "COMPILE"
    case link = "LINK"
    case transfer = "TRANSFER"
    case load = "LOAD"
    case register = "REGISTER"
    case verify = "VERIFY"
}

/// A failure attributed to a stage, with the recovery action spelled out.
/// PRD.md FR-10 requires all four parts.
public struct EmberError: Error, Codable, Sendable, CustomStringConvertible {
    public enum Recovery: String, Codable, Sendable {
        /// The process is fine; fix the source and save again.
        case editAndRetry
        /// The change cannot be applied to a running process.
        case rebuild
        /// The process may be in an uncertain state.
        case restart
        /// Nothing is wrong with the source or the process; the project is not
        /// set up the way this tool needs. Distinct from `rebuild` because
        /// building again changes nothing until a setting does.
        case configure
    }

    public let stage: Stage
    public let subject: String
    public let reason: String
    public let recovery: Recovery

    public init(stage: Stage, subject: String, reason: String, recovery: Recovery) {
        self.stage = stage
        self.subject = subject
        self.reason = reason
        self.recovery = recovery
    }

    public var description: String {
        let action = switch recovery {
        case .editAndRetry: "Action: fix the source and save again."
        case .rebuild: "Action: full rebuild required."
        case .restart: "Action: restart the app."
        case .configure: "Action: fix the project configuration."
        }
        return "[\(stage.rawValue)] \(subject)\n\(reason)\n\n\(action)"
    }
}

/// One structured event per stage, per DESIGN.md section 18.
public struct StageEvent: Codable, Sendable {
    public let generation: UInt64
    public let stage: Stage
    public let durationMs: Double
    public let success: Bool

    public init(generation: UInt64, stage: Stage, durationMs: Double, success: Bool) {
        self.generation = generation
        self.stage = stage
        self.durationMs = durationMs
        self.success = success
    }
}

/// Collects stage timings for one generation so the CLI can print the summary
/// that decides whether the ORC and persistent-compiler work in sections 14 and
/// 15 is justified.
public final class StageTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StageEvent] = []
    public let generation: UInt64

    public init(generation: UInt64) { self.generation = generation }

    public func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try body()
            record(stage, since: start, success: true)
            return value
        } catch {
            record(stage, since: start, success: false)
            throw error
        }
    }

    public func record(_ stage: Stage, since start: UInt64, success: Bool) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.withLock { events.append(StageEvent(generation: generation, stage: stage, durationMs: ms, success: success)) }
    }

    public var all: [StageEvent] { lock.withLock { events } }

    public var totalMs: Double { all.reduce(0) { $0 + $1.durationMs } }

    /// The CLI summary from DESIGN.md section 18.
    public func summary() -> String {
        var lines = all.map { event in
            let name = event.stage.rawValue.lowercased()
            return name.padding(toLength: 22, withPad: " ", startingAt: 0)
                + String(format: "%6.0f ms", event.durationMs)
        }
        lines.append(String(repeating: "-", count: 32))
        lines.append("total".padding(toLength: 22, withPad: " ", startingAt: 0)
            + String(format: "%6.0f ms", totalMs))
        return lines.joined(separator: "\n")
    }
}
