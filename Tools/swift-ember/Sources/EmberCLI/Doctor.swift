import Foundation
import EmberCore
import EmberDaemon

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

        if let device = context.deviceIdentifier {
            let devices = shell("/usr/bin/xcrun", ["devicectl", "list", "devices"])
            let line = devices.split(separator: "\n").first { $0.contains(device) }.map(String.init)
            check("Physical device", line ?? "connect and unlock \(device)",
                  passed: line?.contains("connected") == true && line?.contains("physical") == true)
            check("Patch signing", context.codeSigningIdentity ?? "pass --signing-identity or configure Development signing",
                  passed: context.codeSigningIdentity?.isEmpty == false)
        } else if let simulator = context.simulatorIdentifier {
            let devices = shell("/usr/bin/xcrun", ["simctl", "list", "devices"])
            let line = devices.split(separator: "\n").first { $0.contains(simulator) }.map(String.init)
            check("Simulator", line ?? "boot the selected simulator \(simulator)",
                  passed: line?.contains("(Booted)") == true)
        } else {
            let booted = shell("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"])
            let hasDevice = booted.contains("Booted")
            check("Simulator", hasDevice ? "a device is booted" : "boot a simulator", passed: hasDevice)
        }

        let binary = context.linkTarget
        let built = FileManager.default.fileExists(atPath: binary)
        check("App binary", built ? binary : "build the app first", passed: built)

        let watched = watchedModules(context: context)
        let watchesAppModule = watched.contains(context.moduleName)
        check("Watched modules", watched.isEmpty
              ? "no Swift sources found under the configured source roots"
              : watched.joined(separator: ", "),
              passed: !watched.isEmpty)

        // The two settings that decide whether hot reload can work at all.
        var keys = 0
        if built {
            let symbols = shell("/usr/bin/xcrun", ["nm", "-gU", binary])
            keys = symbols.split(separator: "\n").filter { $0.hasSuffix("Tx") }.count
        }
        check("Replacement keys", keys > 0 ? "\(keys) exported"
              : "none exported; the settings above may be right but the built binary disagrees, so rebuild",
              passed: keys > 0)

        // Per module, because a project is rarely one. Xcode does not pass
        // OTHER_SWIFT_FLAGS into Swift package targets, so a package can sit
        // in a correctly configured project exporting nothing -- and an edit
        // in it would otherwise just appear to do nothing.
        if built {
            let inventory = ModuleInventory.read(from: binary)
            if inventory.patchableModules.isEmpty {
                print("  no module exports replacement keys")
            } else {
                for module in inventory.patchableModules {
                    print("  \(module.padding(toLength: 20, withPad: " ", startingAt: 0))"
                          + "\(inventory.keys[module] ?? 0) keys")
                }
                print("  a module missing from this list cannot be patched; see")
                print("  integrations/xcode/Package.md")
            }

            let absent = watched.filter { !inventory.isPatchable($0) }
            check("Watched module keys", absent.isEmpty
                  ? "every watched module exports replacement keys"
                  : "missing from: \(absent.joined(separator: ", ")); configure those targets and rebuild",
                  passed: absent.isEmpty)

            // Asked of the compiler rather than of the settings, and per module,
            // because a local package needs the flag in its own manifest. A
            // type-check of one import line answers it exactly; counting
            // private keys would not, since a module with no private
            // declarations exports none either way.
            // Only inspect modules reachable from the configured source roots.
            // An application can contain unrelated package modules that are
            // intentionally not configured for Ember; reporting those made a
            // working package-only watch look broken.
            let inspected = watched.filter(inventory.isPatchable)
            let missing = inspected.filter { !acceptsPrivateImport($0, context) }
            check("Private imports", missing.isEmpty
                  ? "every watched patchable module accepts @_private"
                  : "missing from: \(missing.joined(separator: ", ")); add -Xfrontend -enable-private-imports and rebuild",
                  passed: missing.isEmpty)
            if !missing.isEmpty {
                print("  without it a patch cannot reach a `private` declaration, and")
                print("  most bodies in most types touch private state.")
            }
        }

        let sourcesExist = context.sourceRoots.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        check("Sources", context.sourceRoots.joined(separator: ", "), passed: sourcesExist)

        // With a real project the settings can be checked before anything is
        // built, which turns "the patch would not have loaded" into "this
        // configuration is not set up", named per setting.
        if let project {
            if watchesAppModule {
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
            } else {
                // These values describe the selected application target. Xcode
                // does not report the corresponding settings for local package
                // targets, so treating the app's values as the package's gave
                // false failures. The built module inventory and compiler
                // probe above are the package-target evidence we can trust.
                check("Package settings",
                      "verified from the built watched modules", passed: true)
            }
            // Not a pass/fail. When the runtime arrives as the EmberRuntime
            // package product it is enabled by the package manifest, not by
            // the app's own conditions -- Xcode does not propagate an app
            // target's compilation conditions into package targets. Failing on
            // this told projects with a perfectly working runtime that they
            // were not ready. It still matters for an app that compiles the
            // runtime sources itself, or that guards its own call sites.
            print("\("Conditions".padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + "\("--".padding(toLength: 6, withPad: " ", startingAt: 0))"
                  + (project.runtimeEnabled
                     ? "EMBER_ENABLED is defined for the app target"
                     : "EMBER_ENABLED is not set; only needed if the app has its own #if"))
            if watchesAppModule && !project.declaredConfigured {
                print("""

                None of the above is set by this tool. The usual way to get all
                of it at once is to base the Debug configuration on
                integrations/xcode/Ember.xcconfig.
                """)
            }
        }

        print()
        print(ok ? "Ready." : "Not ready.")
        return ok
    }

    /// Modules reachable from the exact roots the user asked Ember to watch.
    /// Kept separate from the binary inventory: the latter contains every
    /// linked package, including modules no watched file can ever belong to.
    static func watchedModules(context: BuildContext) -> [String] {
        let resolver = ModuleResolver(appModule: context.moduleName)
        var modules = Set<String>()

        for path in context.sourceRoots {
            let root = URL(fileURLWithPath: path).standardizedFileURL
            if root.pathExtension == "swift" {
                if FileManager.default.fileExists(atPath: root.path) {
                    modules.insert(resolver.module(for: root))
                }
                continue
            }

            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                modules.insert(resolver.module(for: file))
            }
        }
        return modules.sorted()
    }

    /// Whether `module` was built for private imports, asked by compiling the
    /// one line that needs it.
    ///
    /// The source file named does not have to exist: the import is rejected for
    /// the module, not for the file, so any name answers the question.
    private static func acceptsPrivateImport(_ module: String, _ context: BuildContext) -> Bool {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ember-doctor-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return true }
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = directory.appendingPathComponent("Probe.swift")
        guard (try? "@_private(sourceFile: \"Probe.swift\") @testable import \(module)\n"
            .write(to: probe, atomically: true, encoding: .utf8)) != nil else { return true }

        var arguments = ["-typecheck", "-Onone",
                         "-target", context.targetTriple, "-sdk", context.sdkPath]
        for path in context.moduleSearchPaths { arguments += ["-I", path] }
        for path in context.frameworkSearchPaths { arguments += ["-F", path] }
        arguments.append(probe.path)

        let output = shell(context.swiftCompilerPath, arguments)
        return !output.contains("was not compiled for private import")
    }

    private static func shell(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Merged: a diagnostic this reads -- "was not compiled for private
        // import" -- arrives on stderr, and dropping it made the probe below
        // report every project as configured.
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
