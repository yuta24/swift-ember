import Foundation
import EmberCore
import EmberDaemon

/// Command line parsing, kept out of `main.swift`.
///
/// Top-level code is main-actor isolated while a global function is not, so
/// parsing in place means every helper has to be annotated or every global read
/// has to be justified. A value type has neither problem.
public struct Options {
    public enum Command: String {
        case doctor, watch, start, stop, status
    }

    public var command: Command
    public var contextPath = "ember-context.json"
    public var project: String?
    public var workspace: String?
    public var scheme: String?
    public var configuration = "Debug"
    public var sourceRoots: [String] = []
    public var device: String?
    public var signingIdentity: String?
    public var startupTimeout: TimeInterval = 60

    public static let usage = """
    swift-ember <command> [options]

      doctor    check the project, the toolchain, and the running app
      watch     watch sources and patch the running app on save
      start     run watch in the background
      stop      stop the background watcher
      status    show what the daemon would use, without starting it

    Pointing at an Xcode project:

      --project <path.xcodeproj>     or --workspace <path.xcworkspace>
      --scheme <name>                required with either
      --configuration <name>         default Debug
      --sources <dir>[,<dir>...]     default the project's SRCROOT
      --device <CoreDevice-ID>       target a connected physical iOS device
      --signing-identity <name|SHA>  override the patch signing identity
      --startup-timeout <seconds>    wait for background startup (default 60)

    Pointing at a build that emits its own manifest:

      --context <path>               default ./ember-context.json

    Build settings are read from xcodebuild rather than guessed. See DESIGN.md
    section 6.
    """

    public enum ParseError: Error, CustomStringConvertible {
        case help
        case version
        case usage
        case missingValue(String)
        case invalidValue(String, String)
        case unknown(String)
        case bothContainers
        case schemeRequired

        public var description: String {
            switch self {
            case .help, .usage: Options.usage
            case .version: "swift-ember \(EmberVersion.current)"
            case .missingValue(let flag): "\(flag) needs a value"
            case .invalidValue(let flag, let value): "invalid value for \(flag): \(value)"
            case .unknown(let argument): "unknown argument: \(argument)\n\n\(Options.usage)"
            case .bothContainers: "pass --project or --workspace, not both"
            case .schemeRequired: "--scheme is required with --project or --workspace"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> Options {
        var command: Command?
        var options = Options(command: .status)
        var index = 0

        func value(after flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--context": options.contextPath = try value(after: argument)
            case "--project": options.project = try value(after: argument)
            case "--workspace": options.workspace = try value(after: argument)
            case "--scheme": options.scheme = try value(after: argument)
            case "--configuration": options.configuration = try value(after: argument)
            case "--sources":
                options.sourceRoots = try value(after: argument)
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--device": options.device = try value(after: argument)
            case "--signing-identity": options.signingIdentity = try value(after: argument)
            case "--startup-timeout":
                let value = try value(after: argument)
                guard let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 else {
                    throw ParseError.invalidValue(argument, value)
                }
                options.startupTimeout = seconds
            case "-h", "--help":
                throw ParseError.help
            case "-V", "--version":
                throw ParseError.version
            default:
                guard command == nil, let parsed = Command(rawValue: argument) else {
                    throw ParseError.unknown(argument)
                }
                command = parsed
            }
            index += 1
        }

        guard let command else { throw ParseError.usage }
        options.command = command

        if options.project != nil && options.workspace != nil { throw ParseError.bothContainers }
        if (options.project != nil || options.workspace != nil) && options.scheme == nil {
            throw ParseError.schemeRequired
        }
        return options
    }

    /// Resolves the Xcode project, if one was named.
    public func resolveProject() throws -> XcodeProject.Resolved? {
        let container: XcodeProject.Container
        if let project { container = .project(project) }
        else if let workspace { container = .workspace(workspace) }
        else { return nil }

        return try XcodeProject(container: container, scheme: scheme!,
                                configuration: configuration,
                                deviceIdentifier: device)
            .resolve(sourceRoots: sourceRoots)
    }

    /// The project when there is one, the manifest otherwise.
    public func buildContext(project: XcodeProject.Resolved?) throws -> BuildContext {
        if let project {
            var context = project.context
            if let signingIdentity { context.codeSigningIdentity = signingIdentity }
            return context
        }

        let url = URL(fileURLWithPath: contextPath)
        do {
            var context = try BuildContext.load(from: url)
            if let device { context.deviceIdentifier = device }
            if let signingIdentity { context.codeSigningIdentity = signingIdentity }
            return context
        } catch {
            throw EmberError(stage: .watch, subject: url.lastPathComponent, reason: """
                no project and no build context.

                Either point at an Xcode project:

                    swift-ember \(command.rawValue) --project App.xcodeproj --scheme App

                or run a build that emits a manifest at \(url.path). For the
                sample app, run examples/CounterApp/build.sh.
                """, recovery: .rebuild)
        }
    }
}
