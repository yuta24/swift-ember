import Foundation
import EmberCore
import EmberDaemon
import EmberCLI

// DESIGN.md section 21. `attach` is not here yet: one runtime dials a port the
// daemon publishes, so there is nothing to attach to that `watch` does not do.

// `watch` is long-running and usually piped into something. Line buffering
// keeps its output live rather than arriving in blocks when the pipe fills.
setvbuf(stdout, nil, _IOLBF, 0)

func abort(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "skill" {
    let skill: SkillCommand
    do {
        skill = try SkillCommand.parse(Array(arguments.dropFirst()))
    } catch {
        abort("\(error)\n\n\(SkillCommand.usage)", code: 64)
    }
    do {
        try skill.run()
        exit(0)
    } catch {
        abort("\(error)")
    }
}

let options: Options
do {
    options = try Options.parse(arguments)
} catch let error as Options.ParseError {
    if case .help = error { print(Options.usage); exit(0) }
    if case .version = error { print(error.description); exit(0) }
    if case .usage = error { print(Options.usage); exit(64) }
    abort(error.description, code: 64)
}

do {
    if options.command == .initialize {
        try XcodeInit.run(options: options)
        exit(0)
    }
    if options.command == .xcode && options.xcodeAction != .stop
        && !options.appliesToXcodeConfiguration() {
        print("swift-ember: skipping \(ProcessInfo.processInfo.environment["CONFIGURATION"] ?? "this") configuration")
        exit(0)
    }
    if options.command == .stop
        || (options.command == .xcode && options.xcodeAction == .stop) {
        try Lifecycle.stop(options: options)
        exit(0)
    }
} catch {
    abort("\(error)")
}

let resolvedProject: XcodeProject.Resolved?
let context: BuildContext
let startupProgress = options.command == .watch ? Lifecycle.StartupProgress() : nil
do {
    startupProgress?.report("loading build context")
    resolvedProject = try options.resolveProject()
    context = try options.buildContext(project: resolvedProject)
} catch {
    // A background `start` reads these lines back into its own error.
    if let startupProgress {
        startupProgress.reportFailure(String(describing: error))
        exit(1)
    }
    abort("\(error)")
}

switch options.command {
case .status:
    let running = Lifecycle.runningSession(options: options)
    if let running {
        print("daemon             running (pid \(running.pid))")
    } else {
        print("daemon             not running")
    }
    print("module             \(context.moduleName)")
    print("target             \(context.targetTriple)")
    print("sdk                \(context.sdkName)")
    print("compiler           \(context.swiftCompilerVersion)")
    print("bundle id          \(context.bundleIdentifier)")
    // Split up: one `??` chain of optional maps took too long to type-check
    // on Xcode 16 and 26.2.
    let transport: String
    if let identifier = running?.simulatorIdentifier {
        transport = "simulator \(identifier)"
    } else if let identifier = context.deviceIdentifier {
        transport = "physical device \(identifier)"
    } else if let identifier = context.simulatorIdentifier {
        transport = "simulator \(identifier)"
    } else {
        transport = "simulator"
    }
    print("transport          \(transport)")
    if let warning = running?.simulatorWarning { print(warning) }
    if let identity = context.codeSigningIdentity {
        print("signing identity   \(identity)")
    }
    print("app binary         \(context.appBinaryPath)")
    print("sources            \(context.sourceRoots.joined(separator: ", "))")
    if !context.excludedSourcePaths.isEmpty {
        print("excluded           \(context.excludedSourcePaths.joined(separator: ", "))")
    }
    if let rebuildCommand = options.rebuildCommand {
        print("rebuild command    \(rebuildCommand)")
        print("rebuild directory  \(options.rebuildDirectory ?? FileManager.default.currentDirectoryPath)")
        print("rebuild timeout    \(String(format: "%.0f", options.rebuildTimeout)) s")
    }
    print("defines            \(context.extraCompilerFlags.joined(separator: " "))")
    print("build identity     \(context.identity)")

case .doctor:
    if options.checksRelease, let resolvedProject {
        do {
            exit(try ReleaseDoctor.run(project: resolvedProject, appPath: options.releaseApp) ? 0 : 1)
        } catch {
            abort("\(error)")
        }
    }
    exit(Doctor.run(context: context, project: resolvedProject,
                    manifestCacheDirectory: Lifecycle.manifestCacheDirectory(for: options)) ? 0 : 1)

case .start:
    do {
        try Watch.validatePhysicalDevice(context)
        try Lifecycle.start(options: options, context: context)
    } catch {
        abort("\(error)")
    }

case .xcode:
    do {
        let manifest = BuildSourceManifest(context: context)
        if options.xcodeAction == .prepare {
            try await manifest.prepare()
            exit(0)
        }
        if options.xcodeAction == .record {
            try await manifest.record()
            exit(0)
        }
        try await manifest.record(required: false)
        // The automatic rebuild owns the existing watcher, but the Scheme
        // still records the build for future watcher startups.
        if ProcessInfo.processInfo.environment["SWIFT_EMBER_REBUILD"] == "1" {
            print("swift-ember: keeping the current watcher during its automatic rebuild")
            exit(0)
        }
        try Watch.validatePhysicalDevice(context)
        try Lifecycle.restart(options: options, context: context)
    } catch {
        abort("\(error)")
    }

case .initialize, .stop:
    // Handled before resolving the project, so stopping does not depend on a
    // successful build or on xcodebuild still being available.
    fatalError("unreachable")

case .watch:
    // Caught the same way the resolve above is. Left uncaught, anything `watch`
    // throws on the way up -- no built binary, a container it cannot reach, a
    // port it cannot bind -- reached the developer as
    // "Fatal error: Error raised at top level" with the actual message buried
    // inside it.
    do {
        defer { Lifecycle.removeOwnedRecord() }
        try await Watch.run(
            context: context,
            workDirectory: Lifecycle.patchDirectory(for: options),
            session: Lifecycle.session(for: options),
            rebuildCommand: options.rebuildCommand,
            rebuildDirectory: options.rebuildDirectory.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            rebuildTimeout: options.rebuildTimeout,
            startupProgress: startupProgress,
            onReady: { try Lifecycle.markReady(simulator: $0) })
    } catch {
        if let startupProgress {
            startupProgress.reportFailure(String(describing: error))
            exit(1)
        }
        abort("\(error)")
    }
}
