import Foundation
import EmberCore

public enum Status {
    public static func run(options: Options, context: BuildContext) {
        let running = Lifecycle.runningSession(options: options)
        if options.json {
            let session = running?.session ?? Lifecycle.session(for: options)
            CLIJSON.write(StatusDocument(running: running, session: session, context: context, options: options))
            return
        }
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
    }
}
