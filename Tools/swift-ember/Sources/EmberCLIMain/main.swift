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

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as Options.ParseError {
    if case .help = error { print(Options.usage); exit(0) }
    if case .usage = error { print(Options.usage); exit(64) }
    abort(error.description, code: 64)
}

let resolvedProject: XcodeProject.Resolved?
let context: BuildContext
do {
    resolvedProject = try options.resolveProject()
    context = try options.buildContext(project: resolvedProject)
} catch let error as EmberError {
    abort(error.description)
} catch {
    abort("\(error)")
}

switch options.command {
case .status:
    print("module             \(context.moduleName)")
    print("target             \(context.targetTriple)")
    print("sdk                \(context.sdkName)")
    print("compiler           \(context.swiftCompilerVersion)")
    print("bundle id          \(context.bundleIdentifier)")
    print("transport          \(context.deviceIdentifier.map { "physical device \($0)" } ?? "simulator")")
    if let identity = context.codeSigningIdentity {
        print("signing identity   \(identity)")
    }
    print("app binary         \(context.appBinaryPath)")
    print("sources            \(context.sourceRoots.joined(separator: ", "))")
    print("defines            \(context.extraCompilerFlags.joined(separator: " "))")
    print("build identity     \(context.identity)")

case .doctor:
    exit(Doctor.run(context: context, project: resolvedProject) ? 0 : 1)

case .watch:
    // Caught the same way the resolve above is. Left uncaught, anything `watch`
    // throws on the way up -- no built binary, a container it cannot reach, a
    // port it cannot bind -- reached the developer as
    // "Fatal error: Error raised at top level" with the actual message buried
    // inside it.
    do {
        try await Watch.run(context: context)
    } catch let error as EmberError {
        abort(error.description)
    } catch {
        abort("\(error)")
    }
}
