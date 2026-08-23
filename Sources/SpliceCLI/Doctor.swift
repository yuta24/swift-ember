import Foundation
import SpliceCore
import SpliceDaemon

/// DESIGN.md section 21. Every check reports what it looked at, so a failure
/// tells the developer where to go rather than only that something is wrong.
enum Doctor {
    static func run(context: BuildContext) -> Bool {
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

        let binary = context.appBinaryPath
        let built = FileManager.default.fileExists(atPath: binary)
        check("App binary", built ? binary : "run the app's build script", passed: built)

        // The two settings that decide whether hot reload can work at all.
        var keys = 0
        if built {
            let symbols = shell("/usr/bin/xcrun", ["nm", "-gU", binary])
            keys = symbols.split(separator: "\n").filter { $0.hasSuffix("Tx") }.count
        }
        check("Replacement keys", keys > 0 ? "\(keys) exported"
              : "none exported; build with -enable-testing and -Xfrontend -enable-implicit-dynamic",
              passed: keys > 0)

        let sourcesExist = context.sourceRoots.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        check("Sources", context.sourceRoots.joined(separator: ", "), passed: sourcesExist)

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
