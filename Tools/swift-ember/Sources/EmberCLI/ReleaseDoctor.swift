import Foundation
import EmberDaemon

public enum ReleaseDoctor {
    public static func run(project: XcodeProject.Resolved, appPath: String?) throws -> Bool {
        let settings = project.settings
        print("Shipping configuration: \(settings["CONFIGURATION"] ?? "(unknown)")"
              + " (\(settings["PLATFORM_NAME"] ?? "unknown platform"))")

        var ok = true
        func check(_ label: String, _ findings: [String]) {
            print("\(findings.isEmpty ? "OK" : "FAIL")  \(label)"
                  + (findings.isEmpty ? "" : " — \(findings.joined(separator: ", "))"))
            if !findings.isEmpty { ok = false }
        }

        for (label, findings) in settingChecks(settings) {
            check(label, findings)
        }

        let app: URL
        if let appPath {
            app = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
        } else {
            guard let wrapper = settings["WRAPPER_NAME"], wrapper.hasSuffix(".app"),
                  wrapper == (wrapper as NSString).lastPathComponent else {
                throw InspectionError("Xcode did not report the app's WRAPPER_NAME; pass --app")
            }
            // On macOS the executable is under Contents/MacOS, and Xcode can
            // name the executable and wrapper differently on any platform.
            let directory = URL(fileURLWithPath: project.context.appBinaryPath).deletingLastPathComponent()
            guard let wrapperURL = directory.ancestor(named: wrapper) else {
                throw InspectionError("Xcode's executable path is outside \(wrapper); pass --app")
            }
            app = wrapperURL.standardizedFileURL
        }
        print("App bundle: \(app.path)")
        let executable = try executable(in: app, bundleIdentifier: project.context.bundleIdentifier).standardizedFileURL
        // Xcode can report ENABLE_DEBUG_DYLIB=YES even when the optimiser
        // prevents it from emitting one. Inspect the images actually shipped.
        let images = try machOImages(in: app, executable: executable)
        let prefix = app.path + "/"
        for image in images {
            let name = image.path.hasPrefix(prefix) ? String(image.path.dropFirst(prefix.count)) : image.path
            do {
                check(name, try inspect(image))
            } catch {
                check(name, ["inspection failed: \(error)"])
            }
        }
        print(ok ? "Release checks passed." : "Release checks failed.")
        return ok
    }

    static func settingChecks(_ settings: [String: String]) -> [(String, [String])] {
        let frontendPrefix = "-Xfrontend="
        let flags = XcodeProject.parseSettingList(settings["OTHER_SWIFT_FLAGS"]).map { flag in
            flag.hasPrefix(frontendPrefix) ? String(flag.dropFirst(frontendPrefix.count)) : flag
        }
        let replacement = ["-enable-implicit-dynamic", "-enable-dynamic-replacement-chaining", "-enable-private-imports"]
            .filter(flags.contains)
        let testability = ["ENABLE_TESTABILITY", "SWIFT_ENABLE_TESTABILITY"].compactMap { setting in
            settings[setting]?.uppercased() == "YES" ? "\(setting)=YES" : nil
        } + (flags.contains("-enable-testing") ? ["-enable-testing"] : [])
        let definesEmber = flags.contains("-DEMBER_ENABLED") || flags.indices.contains { index in
            flags[index] == "-D" && index + 1 < flags.count && flags[index + 1] == "EMBER_ENABLED"
        }
        let conditions = XcodeProject.parseSettingList(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
        let runtime = (conditions.contains("EMBER_ENABLED")
                       ? ["SWIFT_ACTIVE_COMPILATION_CONDITIONS contains EMBER_ENABLED"] : [])
            + (definesEmber ? ["OTHER_SWIFT_FLAGS defines EMBER_ENABLED"] : [])
        return [("Replacement flags", replacement), ("Testability", testability), ("Runtime condition", runtime)]
    }

    private static func executable(in app: URL, bundleIdentifier: String) throws -> URL {
        let appPlist = app.appendingPathComponent("Info.plist")
        let hasRootPlist = FileManager.default.fileExists(atPath: appPlist.path)
        let plist = hasRootPlist ? appPlist : app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = values["CFBundleExecutable"] as? String, !name.isEmpty, name != ".", name != "..",
              name == (name as NSString).lastPathComponent else {
            throw InspectionError("cannot read CFBundleExecutable from \(app.path); build the app first and match --derived-data-path, or pass --app")
        }
        guard values["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw InspectionError("\(app.path) does not have Xcode's bundle identifier \(bundleIdentifier)")
        }
        let directory = hasRootPlist ? app : app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        return directory.appendingPathComponent(name)
    }

    private static func machOImages(in app: URL, executable: URL) throws -> [URL] {
        guard try isMachO(executable) else {
            throw InspectionError("the app executable is not Mach-O: \(executable.path)")
        }
        var enumerationError: Error?
        guard let walker = FileManager.default.enumerator(
            at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw InspectionError("cannot enumerate \(app.path)")
        }

        var embedded: [URL] = []
        for case let entry as URL in walker {
            // Foundation's enumerator can return /private/tmp where the
            // original product path and executable use /tmp.
            let path = entry.standardizedFileURL
            guard path.path != executable.path else { continue }
            let metadata = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if metadata.isRegularFile == true, metadata.isSymbolicLink != true, try isMachO(path) {
                embedded.append(path)
            }
        }
        if let enumerationError { throw enumerationError }
        return [executable] + embedded.sorted { $0.path < $1.path }
    }

    private static func isMachO(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 8) ?? Data()
        switch Array(bytes.prefix(4)) {
        case [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
             [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
             [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
             [0xbe, 0xba, 0xfe, 0xca]:
            return true
        case [0xca, 0xfe, 0xba, 0xbe]:
            // Java class files share this magic; a universal image has a
            // small architecture count where a class stores its version.
            return bytes.count == 8 && bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0
                && (1...32).contains(bytes[7])
        default:
            return false
        }
    }

    static func inspect(_ image: URL) throws -> [String] {
        let commands = try tool("otool", ["-arch", "all", "-f", "-l", image.path])
        guard commands.contains("Load command 0") else {
            throw InspectionError("otool returned no Mach-O load commands")
        }
        let sections = commands.split(separator: "\n").compactMap { line -> Substring? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0] == "sectname" ? fields[1] : nil
        }
        let symbols = try tool("nm", ["-arch", "all", image.path]).split(separator: "\n").compactMap {
            $0.split(whereSeparator: \.isWhitespace).last
        }
        var findings: [String] = []
        if symbols.contains(where: { name in
            (name.hasPrefix("_$s") || name.hasPrefix("_$S")) && name.hasSuffix("Tx")
        }) {
            findings.append("Swift dynamic replacement keys")
        }
        if sections.contains("__swift5_replace") || sections.contains("__swift5_replac2") {
            findings.append("Swift dynamic replacement sections")
        }
        if try containsEnabledRuntime(image, symbols: symbols, sections: sections, loadCommands: commands) {
            findings.append("enabled Ember runtime")
        }
        return findings
    }

    private static func containsEnabledRuntime(
        _ image: URL, symbols: [Substring], sections: [Substring], loadCommands: String
    ) throws -> Bool {
        let module = "EmberRuntime"
        let moduleIdentifier = "\(module.utf8.count)\(module)"
        // These top-level classes only compile with EMBER_ENABLED.
        let runtimeTypes = ["EmberClient", "EmberDeviceClient", "RuntimePatchApplier"]
        let descriptors = symbols.filter { name in
            // The first identifier in a top-level type descriptor is the
            // module. The class name can reuse words from it via substitutions.
            (name.hasPrefix("_$s\(moduleIdentifier)") || name.hasPrefix("_$S\(moduleIdentifier)"))
                && name.hasSuffix("Mn")
        }
        if !descriptors.isEmpty {
            let expected = Set(runtimeTypes.map { "nominal type descriptor for \(module).\($0)"[...] })
            let demangled = try tool("swift-demangle", ["--compact"] + descriptors.map(String.init))
            if demangled.split(separator: "\n").contains(where: expected.contains) { return true }
        }

        if sections.contains("__swift5_types"),
           try SwiftTypeMetadata.containsClass(in: image, loadCommands: loadCommands, module: module, names: runtimeTypes) {
            return true
        }

        // Some toolchains put the classes' legacy Objective-C runtime names
        // in a dedicated section that is also available after stripping.
        guard sections.contains("__objc_classname") else { return false }
        let expected = Set(runtimeTypes.map { "_TtC\(moduleIdentifier)\($0.utf8.count)\($0)"[...] })
        let classNames = try tool("otool", ["-arch", "all", "-v", "-s", "__TEXT", "__objc_classname", image.path])
        return classNames.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && expected.contains(fields[1])
        }
    }

    private static func tool(_ name: String, _ arguments: [String]) throws -> String {
        let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: [name] + arguments)
        guard result.exitCode == 0 else {
            throw InspectionError("\(name) exited with \(result.exitCode): "
                                  + result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.standardOutput
    }

    struct InspectionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private extension URL {
    func ancestor(named name: String) -> URL? {
        var directory = self
        while !directory.lastPathComponent.isEmpty, directory.path != "/" {
            if directory.lastPathComponent == name { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
