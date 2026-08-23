import Foundation
import SpliceCore
import SpliceDaemon

// DESIGN.md section 21. `attach` is not here yet: M2 has one runtime dialing a
// known port, so there is nothing to attach to that `watch` does not do.

// `watch` is long-running and usually piped into something. Line buffering
// keeps its output live rather than arriving in blocks when the pipe fills.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    swift-splice <command> [--context <path>]

      doctor    check the environment and the running app
      watch     watch sources and patch the running app on save
      status    show what the daemon would use, without starting it

    --context defaults to ./splice-context.json, which the application's build
    emits. See DESIGN.md section 6.
    """)
    exit(64)
}

var contextPath = "splice-context.json"
var command: String?
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--context":
        index += 1
        guard index < arguments.count else { usage() }
        contextPath = arguments[index]
    case "-h", "--help":
        usage()
    case let value where command == nil:
        command = value
    default:
        usage()
    }
    index += 1
}

func loadContext(_ path: String) -> BuildContext {
    let url = URL(fileURLWithPath: path)
    do {
        return try BuildContext.load(from: url)
    } catch {
        FileHandle.standardError.write(Data("""
        cannot read a build context at \(url.path)

        The application's build is responsible for emitting it. For the sample
        app, run examples/CounterApp/build.sh.

        """.utf8))
        exit(1)
    }
}

switch command {
case "status":
    let context = loadContext(contextPath)
    print("module             \(context.moduleName)")
    print("target             \(context.targetTriple)")
    print("sdk                \(context.sdkName)")
    print("compiler           \(context.swiftCompilerVersion)")
    print("bundle id          \(context.bundleIdentifier)")
    print("app binary         \(context.appBinaryPath)")
    print("sources            \(context.sourceRoots.joined(separator: ", "))")
    print("build identity     \(context.identity)")

case "doctor":
    exit(Doctor.run(context: loadContext(contextPath)) ? 0 : 1)

case "watch":
    try await Watch.run(context: loadContext(contextPath))

default:
    usage()
}
