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
