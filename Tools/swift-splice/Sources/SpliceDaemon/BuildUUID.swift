import Foundation

/// The linker's UUIDs for a Mach-O image, one per architecture slice.
///
/// This is the one part of a build identity that changes when the *build*
/// changes rather than when the toolchain or the target does. Without it,
/// `BuildContext.identity` --- module, triple, SDK, compiler version --- is
/// equal for a running process and for a newer build of the same sources on
/// the same toolchain, which is exactly the pair that must not be confused: the
/// daemon compiles patches against what is on disk, and the process is running
/// what was on disk when it launched. It was the one check in a fail-closed
/// design that could pass while being wrong.
///
/// Every slice, not one. A Simulator build is universal, and `dwarfdump` prints
/// a line per architecture with a *different* UUID on each; taking the first
/// gave the x86_64 slice's while the process ran arm64, which would have
/// rejected every patch ever sent. The runtime intersects this set with what it
/// has loaded, so which slice it is running does not have to be guessed.
public final class BuildUUID: @unchecked Sendable {
    /// Re-read whenever the file changes, and not once per session.
    ///
    /// Caching it for the session, the way the module inventory is cached, was
    /// wrong here and wrong in a way that removed the whole point: the
    /// inventory's excuse is that a rebuild means a relaunch, and *this* check
    /// exists precisely because it does not. A rebuild with the app still
    /// running leaves the daemon linking patches against a binary the process
    /// is not executing, which is the one case the identity is supposed to
    /// catch -- and a cached value from before the rebuild still matched.
    ///
    /// Keyed on size and modification date, so the reader runs once per build
    /// rather than once per save. It costs about 10 ms when it does run, which
    /// is 3% of a reload and only on the save after a rebuild.
    private let binary: String
    private let lock = NSLock()
    private var cached: (key: String, uuids: [String])?

    public init(binary: String) {
        self.binary = binary
    }

    public func current() -> [String] {
        let key = Self.stamp(of: binary)
        return lock.withLock {
            if let cached, cached.key == key { return cached.uuids }
            let uuids = Self.read(from: binary)
            cached = (key, uuids)
            return uuids
        }
    }

    private static func stamp(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)|\(modified)"
    }
}

extension BuildUUID {
    /// Read from the binary the patch will link against.
    ///
    /// `dwarfdump --uuid` rather than parsing Mach-O here: the daemon already
    /// shells out to `nm` for the module inventory, and one more line of output
    /// to read is cheaper than a second Mach-O reader to keep correct. The
    /// runtime has to parse headers because it has no shell, and that reader is
    /// the one worth having.
    static func read(from binary: String) -> [String] {
        guard let result = try? Subprocess.run("/usr/bin/xcrun",
                                               arguments: ["dwarfdump", "--uuid", binary]),
              result.exitCode == 0
        else { return [] }

        // "UUID: 1B2C3D4E-... (arm64) /path/to/binary"
        return result.standardOutputLines.compactMap { line in
            guard line.hasPrefix("UUID:") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }
    }
}
