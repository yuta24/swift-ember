#if SPLICE_ENABLED

import Foundation
import MachO

/// How many dynamic replacements an image actually registered.
///
/// PRD.md FR-13: a patch that loads without error but replaces nothing must be
/// reported as a failure, not a success. `dlopen` returning a handle says the
/// image mapped, not that the Swift runtime bound anything in it, and the whole
/// reason this project refuses SwiftUI `body` is that a reload which lies is
/// worse than a refusal.
///
/// The count comes out of the image's own `__TEXT,__swift5_replace` section,
/// which is what the Swift runtime reads at load time. Reading the same thing
/// it reads is the closest an observable check can get without runtime
/// internals.
///
/// The layout is measured, not documented, and pinned by
/// `fixtures/Cases/registered-replacements`:
///
/// ```text
/// section   uint32 flags
///           uint32 numScopes
///           per scope: int32 relative pointer, uint32 flags
/// scope     uint32 flags
///           uint32 numReplacements
///           descriptors...
/// ```
///
/// A toolchain that changes it should break that fixture rather than a user's
/// session, which is why an unreadable section reports "not verified" instead
/// of a failure. A section that is present and says zero is a failure: that is
/// the case FR-13 names.
enum RegisteredReplacements {
    /// The number registered, or nil when the image could not be examined.
    static func count(inImageAt path: String) -> Int? {
        guard let header = header(forImageAt: path) else { return nil }

        var size: UInt = 0
        guard let base = getsectiondata(header, "__TEXT", "__swift5_replace", &size) else {
            // No section at all: the image registered nothing.
            return 0
        }
        guard size >= 8 else { return 0 }

        let words = UnsafeRawPointer(base)
        let numScopes = Int(words.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard numScopes > 0 else { return 0 }
        guard size >= UInt(8 + numScopes * 8) else { return nil }

        var total = 0
        for index in 0..<numScopes {
            let entry = words.advanced(by: 8 + index * 8)
            let relative = entry.loadUnaligned(as: Int32.self)
            guard relative != 0 else { continue }
            // A RelativeIndirectablePointer stores "indirect" in the low bit.
            let indirect = relative & 1 == 1
            let target = entry.advanced(by: Int(relative & ~1))
            let scope = indirect
                ? UnsafeRawPointer(bitPattern: target.loadUnaligned(as: UInt.self))
                : target
            guard let scope else { return nil }
            total += Int(scope.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        return total
    }

    /// The loaded image with this path.
    ///
    /// Matched on the last component rather than the whole path: the daemon
    /// delivers into the app's container and dyld reports the path it opened,
    /// and `/private` symlinking makes the two differ on a simulator. Patch
    /// names are unique per generation, so the component is enough.
    private static func header(forImageAt path: String) -> UnsafePointer<mach_header_64>? {
        let name = (path as NSString).lastPathComponent
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            guard (String(cString: raw) as NSString).lastPathComponent == name else { continue }
            guard let header = _dyld_get_image_header(index) else { continue }
            return UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        }
        return nil
    }
}

#endif
