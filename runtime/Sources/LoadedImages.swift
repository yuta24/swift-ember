#if EMBER_ENABLED

import Foundation
import MachO

/// The UUIDs of the Mach-O images this process has loaded.
///
/// The point of asking the process rather than the daemon. Every other field in
/// the handshake is a string the daemon wrote into the session file and the
/// runtime read back, so comparing them proved only that one daemon wrote both.
/// A linker UUID is the one identifier that changes with the build and can be
/// read from inside the process that is running it.
///
/// Parsed here rather than shelled out for, because a runtime has no shell.
enum LoadedImages {
    /// True if any loaded image carries one of these UUIDs.
    ///
    /// A set rather than one value: a Simulator binary is universal and each
    /// architecture slice has its own UUID, so the daemon sends all of them and
    /// the process matches whichever slice it happens to be running.
    static func running(oneOf expected: [String]) -> Bool {
        guard !expected.isEmpty else {
            // Nothing to check against. The daemon could not read the binary,
            // which is its problem to report; refusing here would turn a
            // missing diagnostic into a broken session.
            return true
        }
        let wanted = Set(expected.map { $0.uppercased() })
        return uuids().contains { wanted.contains($0) }
    }

    static func uuids() -> Set<String> {
        var found: Set<String> = []
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            guard let uuid = uuid(ofImageAt: UnsafeRawPointer(header)) else { continue }
            found.insert(uuid)
        }
        return found
    }

    /// Walks an image's load commands for `LC_UUID`.
    private static func uuid(ofImageAt header: UnsafeRawPointer) -> String? {
        let magic = header.assumingMemoryBound(to: UInt32.self).pointee
        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { return nil }

        let head = header.assumingMemoryBound(to: mach_header_64.self)
        var cursor = header.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<head.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            // A zero-sized command would loop forever on a malformed image.
            guard command.cmdsize > 0 else { return nil }
            if command.cmd == LC_UUID {
                let uuid = cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}

#endif
