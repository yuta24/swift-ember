import Foundation
import SpliceCore

/// Which modules the running binary will actually accept a patch for.
///
/// Read out of the binary rather than inferred from build settings, because
/// the settings do not say. Xcode propagates `SWIFT_OPTIMIZATION_LEVEL` and
/// `SWIFT_ENABLE_TESTABILITY` into Swift package targets but not
/// `OTHER_SWIFT_FLAGS`, so a local package compiles without implicit dynamic
/// and produces no replacement keys at all --- while every build setting the
/// daemon can see still says the project is configured correctly.
///
/// Counting the keys the binary exports, per module, is the one check that
/// cannot be fooled by that.
public struct ModuleInventory: Sendable {
    /// Module name to the number of replacement keys it exports.
    public let keys: [String: Int]

    public func isPatchable(_ module: String) -> Bool { (keys[module] ?? 0) > 0 }

    public var patchableModules: [String] { keys.keys.sorted() }

    public static func read(from binary: String) -> ModuleInventory {
        guard let result = try? Subprocess.run("/usr/bin/xcrun",
                                               arguments: ["nm", "-gU", binary]) else {
            return ModuleInventory(keys: [:])
        }
        var counts: [String: Int] = [:]
        for line in result.standardOutputLines where line.hasSuffix("Tx") {
            guard let symbol = line.split(separator: " ").last,
                  let module = moduleName(ofMangled: String(symbol)) else { continue }
            counts[module, default: 0] += 1
        }
        return ModuleInventory(keys: counts)
    }

    /// The module out of a mangled Swift symbol.
    ///
    /// `_$s7Feature7GreeterV8greetingSSyFTx` begins, after the `_$s` prefix,
    /// with a length-prefixed identifier -- the module. Nothing more of the
    /// mangling needs decoding to answer the only question here.
    static func moduleName(ofMangled symbol: String) -> String? {
        var rest = Substring(symbol)
        for prefix in ["_$s", "$s", "_$S", "$S"] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            break
        }
        let digits = rest.prefix(while: \.isNumber)
        guard let length = Int(digits), length > 0 else { return nil }
        let body = rest.dropFirst(digits.count)
        guard body.count >= length else { return nil }
        return String(body.prefix(length))
    }
}

extension Subprocess.Result {
    var standardOutputLines: [String] {
        combinedOutput.split(separator: "\n").map(String.init)
    }
}
