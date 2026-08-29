import Foundation

/// The Swift language mode a local package's target is built in.
///
/// `xcodebuild -showBuildSettings` reports the targets of the scheme, and a
/// local package's are not among them --- so the daemon has one `BuildContext`,
/// the application's, and used it for every file including a package's. In the
/// example project that meant compiling a Swift 6 package's file under
/// `-swift-version 5`.
///
/// Measured, and it is not cosmetic: a body using `Task { }` over a
/// non-`Sendable` capture was accepted into the running process, while the
/// project's own build of that identical file fails with "sending value of
/// non-Sendable type risks causing data races". The guard against exactly that
/// exists in `XcodeProject` and was per-project, where the language mode is
/// per-module.
///
/// Read from the manifest, because there is nowhere else to read it from
/// without building the package.
public enum PackageLanguageMode: Sendable {
    case mode(String)
    /// The manifest says something this cannot evaluate. Refusing beats
    /// guessing: the wrong mode is not a compile error, it is a body that
    /// type-checks under rules the developer did not choose.
    case unknown(String)

    public static func read(from manifest: URL) -> PackageLanguageMode {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            return .unknown("could not read \(manifest.lastPathComponent)")
        }

        // An explicit setting wins over the tools version, and is the one shape
        // worth pattern-matching: evaluating a manifest means running it.
        if text.contains("swiftLanguageMode(") {
            guard let range = text.range(of: #"swiftLanguageMode\(\s*\.v([0-9_]+)"#,
                                         options: .regularExpression) else {
                return .unknown("its manifest sets swiftLanguageMode to something this cannot read")
            }
            let version = text[range].split(separator: "v").last.map { $0.replacingOccurrences(of: "_", with: ".") }
            return version.map { .mode($0) } ?? .unknown("its manifest sets an unreadable swiftLanguageMode")
        }

        guard let line = text.split(separator: "\n").first(where: {
            $0.lowercased().contains("swift-tools-version")
        }) else {
            return .unknown("its manifest declares no swift-tools-version")
        }
        let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        guard let major = digits.split(separator: ".").first.map(String.init) else {
            return .unknown("its manifest's swift-tools-version could not be read")
        }

        // Tools 6 and later default their targets to the Swift 6 language mode;
        // 5 to Swift 5. Anything older is not a mode this tool has measured.
        switch major {
        case let value where (Int(value) ?? 0) >= 6: return .mode("6")
        case "5": return .mode("5")
        default: return .unknown("its manifest declares swift-tools-version \(digits), which this tool has not measured")
        }
    }
}
