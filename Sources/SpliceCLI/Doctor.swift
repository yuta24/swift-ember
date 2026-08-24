import Foundation
import SpliceCore
import SpliceDaemon

/// DESIGN.md section 21. Every check reports what it looked at, so a failure
/// tells the developer where to go rather than only that something is wrong.
public enum Doctor {
    public static func run(context: BuildContext, project: XcodeProject.Resolved? = nil) -> Bool {
        var ok = true

        func check(_ label: String, _ detail: String?, passed: Bool) {
            let mark = passed ? "OK" : "FAIL"
            let padded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("\(padded)\(mark.padding(toLength: 6, withPad: " ", startingAt: 0))\(detail ?? "")")
            if !passed { ok = false }
        }

        let xcode = shell("/usr/bin/xcode-select", ["-p"])
        check("Xcode", xcode, passed: !xcode.isEmpty)

        let version = shell(context.swiftCompilerPath, ["--version"]).split(separator: "\n").first.map(String.init) ?? ""
        check("Swift toolchain", version, passed: version.contains(context.swiftCompilerVersion) || !version.isEmpty)

        let booted = shell("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"])
        let hasDevice = booted.contains("Booted")
        check("Simulator", hasDevice ? "a device is booted" : "boot a simulator", passed: hasDevice)

        let binary = context.linkTarget
        let built = FileManager.default.fileExists(atPath: binary)
        check("App binary", built ? binary : "build the app first", passed: built)

        // The two settings that decide whether hot reload can work at all.
        var keys = 0
        if built {
            let symbols = shell("/usr/bin/xcrun", ["nm", "-gU", binary])
            keys = symbols.split(separator: "\n").filter { $0.hasSuffix("Tx") }.count
        }
        check("Replacement keys", keys > 0 ? "\(keys) exported"
              : "none exported; the settings above may be right but the built binary disagrees, so rebuild",
              passed: keys > 0)

        let sourcesExist = context.sourceRoots.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        check("Sources", context.sourceRoots.joined(separator: ", "), passed: sourcesExist)

        // With a real project the settings can be checked before anything is
        // built, which turns "the patch would not have loaded" into "this
        // configuration is not set up", named per setting.
        if let project {
            check("Optimisation", project.optimisationDisabled
                  ? "-Onone" : "set SWIFT_OPTIMIZATION_LEVEL = -Onone; replacement dispatch does not survive optimisation",
                  passed: project.optimisationDisabled)
            check("Testability", project.testabilityEnabled
                  ? "SWIFT_ENABLE_TESTABILITY = YES"
                  : "set SWIFT_ENABLE_TESTABILITY = YES, or the replacement keys stay hidden",
                  passed: project.testabilityEnabled)
            check("Implicit dynamic", project.implicitDynamicEnabled
                  ? "-Xfrontend -enable-implicit-dynamic"
                  : "add -Xfrontend -enable-implicit-dynamic to OTHER_SWIFT_FLAGS",
                  passed: project.implicitDynamicEnabled)
            // Not a pass/fail. When the runtime arrives as the SpliceRuntime
            // package product it is enabled by the package manifest, not by
            // the app's own conditions -- Xcode does not propagate an app
            // target's compilation conditions into package targets. Failing on
            // this told projects with a perfectly working runtime that they
            // were not ready. It still matters for an app that compiles the
            // runtime sources itself, or that guards its own call sites.
            print("\("Conditions".padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + "\("--".padding(toLength: 6, withPad: " ", startingAt: 0))"
                  + (project.runtimeEnabled
                     ? "SPLICE_ENABLED is defined for the app target"
                     : "SPLICE_ENABLED is not set; only needed if the app has its own #if"))
            if !project.declaredConfigured {
                print("""

                None of the above is set by this tool. The usual way to get all
                of it at once is to base the Debug configuration on
                integrations/xcode/Splice.xcconfig.
                """)
            }
        }

        print()
        print(ok ? "Ready." : "Not ready.")
        return ok
    }

    private static func shell(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
