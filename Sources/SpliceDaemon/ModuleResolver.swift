import Foundation

/// Which module a source file belongs to.
///
/// Inferred from the path rather than configured, because the build system
/// does not offer it: `xcodebuild -showBuildSettings` reports only the targets
/// of the scheme, and a local Swift package's targets are not among them.
///
/// The inference is the layout SwiftPM requires -- a target's sources live
/// under `Sources/<TargetName>/` beneath a `Package.swift` -- and a wrong
/// answer does not pass silently: the module has to exist in the built
/// products and to export replacement keys, both of which are checked against
/// the binary before anything is generated.
public struct ModuleResolver: Sendable {
    public let appModule: String

    public init(appModule: String) {
        self.appModule = appModule
    }

    /// The module a file belongs to, and the manifest of the package it came
    /// from when it came from one.
    ///
    /// The manifest is what the language mode has to be read out of: the build
    /// settings do not carry a package target's, and using the application's
    /// for a package's file compiles it under rules the developer did not
    /// choose.
    public struct Resolution: Sendable {
        public let module: String
        public let manifest: URL?
    }

    public func resolve(_ url: URL) -> Resolution {
        var directory = url.deletingLastPathComponent()
        var trail: [String] = []

        while directory.path != "/" {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                if let index = trail.lastIndex(of: "Sources"), index + 1 < trail.count {
                    return Resolution(module: trail[index + 1], manifest: manifest)
                }
                // A manifest above the file is not evidence the file is a
                // package target's. An app whose sources sit inside a
                // repository that happens to contain a Package.swift -- this
                // one's own examples, for instance -- found it, and every patch
                // was then compiled in that package's language mode instead of
                // the app's.
                return Resolution(module: appModule, manifest: nil)
            }
            trail.insert(directory.lastPathComponent, at: 0)
            directory = directory.deletingLastPathComponent()
        }
        return Resolution(module: appModule, manifest: nil)
    }

    public func module(for url: URL) -> String {
        var directory = url.deletingLastPathComponent()
        var trail: [String] = []

        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path) {
                // Inside a package. `Sources/<Target>/...` names the module;
                // anything else in the package is not a target's source.
                if let index = trail.lastIndex(of: "Sources"), index + 1 < trail.count {
                    return trail[index + 1]
                }
                return appModule
            }
            trail.insert(directory.lastPathComponent, at: 0)
            directory = directory.deletingLastPathComponent()
        }
        return appModule
    }
}
