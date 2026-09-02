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
        case doctor, watch, start, stop, status, xcode
    }

    public enum XcodeAction: String {
        case start, stop
    }

    public var command: Command
    public var xcodeAction: XcodeAction?
    public var configPath: String?
    public var ignoresProjectConfiguration = false
    public var contextPath = "ember-context.json"
    public var project: String?
    public var workspace: String?
    public var scheme: String?
    public var configuration = "Debug"
    public var sourceRoots: [String] = []
    /// Nil means an emitted context keeps its own exclusions. An explicit or
    /// project-configured empty array deliberately clears them.
    public var excludedSourcePaths: [String]?
    public var device: String?
    /// Populated from Xcode's environment for Scheme actions. This is kept
    /// separate from `device`, whose presence selects the physical transport.
    public var simulator: String?
    public var signingIdentity: String?
    public var startupTimeout: TimeInterval = 60

    public static let usage = """
    swift-ember <command> [options]

      doctor    check the project, the toolchain, and the running app
      watch     watch sources and patch the running app on save
      start     run watch in the background
      stop      stop the background watcher
      status    show what the daemon would use, without starting it
      xcode     own the watcher from Xcode Scheme actions

    Xcode Scheme actions:

      xcode start                     restart after a successful Debug build
      xcode stop                      stop when the app exits

    Pointing at an Xcode project:

      --config <path.json>            defaults to the nearest .swift-ember.json
      --no-config                     do not discover a project configuration
      --project <path.xcodeproj>     or --workspace <path.xcworkspace>
      --scheme <name>                required with either
      --configuration <name>         default Debug
      --sources <dir>[,<dir>...]     default the project's SRCROOT
      --exclude <path>[,<path>...]   omit files or directories from change monitoring
      --device <CoreDevice-ID>       target a connected physical iOS device
      --simulator <Simulator-UDID>   target a specific iOS Simulator
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
        case xcodeActionRequired
        case xcodeProjectRequired
        case configuration(String)
        case bothTargetModes
        case conflictingDestinations
        case conflictingConfigurationFlags

        public var description: String {
            switch self {
            case .help, .usage: Options.usage
            case .version: "swift-ember \(EmberVersion.current)"
            case .missingValue(let flag): "\(flag) needs a value"
            case .invalidValue(let flag, let value): "invalid value for \(flag): \(value)"
            case .unknown(let argument): "unknown argument: \(argument)\n\n\(Options.usage)"
            case .bothContainers: "pass --project or --workspace, not both"
            case .schemeRequired: "--scheme is required with --project or --workspace"
            case .xcodeActionRequired: "xcode needs an action: start or stop"
            case .xcodeProjectRequired:
                "xcode needs a project or workspace, either in .swift-ember.json or Xcode's environment"
            case .configuration(let reason): reason
            case .bothTargetModes:
                "pass --context or --project/--workspace, not both"
            case .conflictingDestinations:
                "pass --device or --simulator, not both"
            case .conflictingConfigurationFlags:
                "pass --config or --no-config, not both"
            }
        }
    }

    struct ExplicitOptions {
        var context = false
        var container = false
        var scheme = false
        var configuration = false
        var sources = false
        var excludes = false
        var device = false
        var simulator = false
        var startupTimeout = false
    }

    public static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> Options {
        var command: Command?
        var options = Options(command: .status)
        var explicit = ExplicitOptions()
        var explicitConfigurationFile = false
        var index = 0

        func value(after flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config":
                options.configPath = try value(after: argument)
                explicitConfigurationFile = true
            case "--no-config": options.ignoresProjectConfiguration = true
            case "--context":
                options.contextPath = try value(after: argument)
                explicit.context = true
            case "--project":
                options.project = try value(after: argument)
                explicit.container = true
            case "--workspace":
                options.workspace = try value(after: argument)
                explicit.container = true
            case "--scheme":
                options.scheme = try value(after: argument)
                explicit.scheme = true
            case "--configuration":
                options.configuration = try value(after: argument)
                explicit.configuration = true
            case "--sources":
                options.sourceRoots = try value(after: argument)
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                explicit.sources = true
            case "--exclude":
                options.excludedSourcePaths = try value(after: argument)
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                explicit.excludes = true
            case "--device":
                options.device = try value(after: argument)
                explicit.device = true
            case "--simulator":
                options.simulator = try value(after: argument)
                explicit.simulator = true
            case "--signing-identity": options.signingIdentity = try value(after: argument)
            case "--startup-timeout":
                let value = try value(after: argument)
                guard let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 else {
                    throw ParseError.invalidValue(argument, value)
                }
                options.startupTimeout = seconds
                explicit.startupTimeout = true
            case "-h", "--help":
                throw ParseError.help
            case "-V", "--version":
                throw ParseError.version
            default:
                guard command == nil, let parsed = Command(rawValue: argument) else {
                    throw ParseError.unknown(argument)
                }
                command = parsed
                if parsed == .xcode {
                    index += 1
                    guard index < arguments.count,
                          let action = XcodeAction(rawValue: arguments[index]) else {
                        throw ParseError.xcodeActionRequired
                    }
                    options.xcodeAction = action
                }
            }
            index += 1
        }

        guard let command else { throw ParseError.usage }
        options.command = command

        if explicit.context && explicit.container { throw ParseError.bothTargetModes }
        if explicitConfigurationFile && options.ignoresProjectConfiguration {
            throw ParseError.conflictingConfigurationFlags
        }

        // A complete command-line target is self-contained and must remain a
        // recovery path when a nearby configuration is malformed. An explicit
        // --config is still read because the caller asked for that file.
        let hasCompleteExplicitTarget = explicit.context
            || (explicit.container && explicit.scheme)

        do {
            if !options.ignoresProjectConfiguration,
               (explicitConfigurationFile || !hasCompleteExplicitTarget),
               let (configuration, url) = try ProjectConfiguration.discover(
                explicitPath: options.configPath,
                environment: environment,
                currentDirectory: currentDirectory) {
                options.configPath = url.path
                configuration.applying(to: &options, from: url, explicit: explicit)
            }
        } catch {
            throw ParseError.configuration("\(error)")
        }

        if command == .xcode {
            if !explicit.container, options.project == nil, options.workspace == nil {
                if let workspace = environment["WORKSPACE_PATH"], !workspace.isEmpty {
                    options.workspace = workspace
                } else if let project = environment["PROJECT_FILE_PATH"], !project.isEmpty {
                    options.project = project
                }
            }
            if !explicit.device, !explicit.simulator,
               options.device == nil, options.simulator == nil,
               let platform = environment["PLATFORM_NAME"],
               let rawIdentifier = environment["TARGET_DEVICE_IDENTIFIER"] {
                let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalised = identifier.lowercased()
                // Physical CoreDevice UDIDs are not necessarily RFC UUIDs;
                // current devices commonly use `00008120-<hex>`. Simulator
                // identifiers are UUIDs today, but both are opaque here. Reject
                // only Xcode's generic destinations rather than imposing a
                // format on either kind of real destination.
                if !identifier.isEmpty,
                   !normalised.contains("placeholder"),
                   !normalised.hasPrefix("generic/") {
                    if platform == "iphoneos" {
                        options.device = identifier
                    } else if platform == "iphonesimulator" {
                        options.simulator = identifier
                    }
                }
            }
        }

        if options.device != nil && options.simulator != nil {
            throw ParseError.conflictingDestinations
        }
        if options.project != nil && options.workspace != nil { throw ParseError.bothContainers }
        if (options.project != nil || options.workspace != nil) && options.scheme == nil {
            throw ParseError.schemeRequired
        }
        if command == .xcode && options.project == nil && options.workspace == nil {
            throw ParseError.xcodeProjectRequired
        }
        return options
    }

    public func appliesToXcodeConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let current = environment["CONFIGURATION"], !current.isEmpty else { return true }
        return current == configuration
    }

    /// Resolves the Xcode project, if one was named.
    public func resolveProject() throws -> XcodeProject.Resolved? {
        let container: XcodeProject.Container
        if let project { container = .project(project) }
        else if let workspace { container = .workspace(workspace) }
        else { return nil }

        return try XcodeProject(container: container, scheme: scheme!,
                                configuration: configuration,
                                deviceIdentifier: device,
                                simulatorIdentifier: simulator)
            .resolve(sourceRoots: sourceRoots,
                     excludedSourcePaths: excludedSourcePaths ?? [])
    }

    /// The project when there is one, the manifest otherwise.
    public func buildContext(project: XcodeProject.Resolved?) throws -> BuildContext {
        if let project {
            var context = project.context
            if let excludedSourcePaths { context.excludedSourcePaths = excludedSourcePaths }
            if let signingIdentity { context.codeSigningIdentity = signingIdentity }
            return context
        }

        let url = URL(fileURLWithPath: contextPath)
        do {
            var context = try BuildContext.load(from: url)
            if let excludedSourcePaths { context.excludedSourcePaths = excludedSourcePaths }
            if let device {
                context.deviceIdentifier = device
                context.simulatorIdentifier = nil
            }
            if let simulator {
                context.deviceIdentifier = nil
                context.simulatorIdentifier = simulator
            }
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
