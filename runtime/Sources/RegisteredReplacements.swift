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
/// The layout is measured, not documented. `fixtures/Cases/registered-replacements`
/// compiles this file into a fixture application and asks it about a real
/// loaded image, so a toolchain that moves a field breaks that case rather
/// than somebody's session. That case is the only place this reader runs, and
/// it only covers this section while its subject still emits one --- which it
/// stopped doing once, silently, when a plain method was moved into an
/// `@objcMembers` class:
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
    ///
    /// Two mechanisms are counted, because the compiler picks one per
    /// declaration and never both. A Swift method's replacement goes into the
    /// section above. An `@objc` member's does not: measured, a patch
    /// replacing `viewDidLoad` has no `__swift5_replace` section at all and
    /// carries an Objective-C category instead, which the Objective-C runtime
    /// installs over the class's own method at image load. The fixtures
    /// `objc-method`, `override-objc-dispatch`, and `uikit-view-did-load`
    /// measure that the replacement takes effect; `nm` on their patches shows
    /// a `__CATEGORY_INSTANCE_METHODS__...` and no `Tx` reference.
    ///
    /// Counting only the first made every UIKit lifecycle edit fail: the
    /// patch replaced `viewDidLoad`, the screen changed, and the daemon
    /// reported "the patch loaded and registered no replacements at all" and
    /// ended the session. That is FR-13 firing on a reload that worked.
    static func count(inImageAt path: String) -> Int? {
        guard let header = header(forImageAt: path) else { return nil }
        let categories = categoryImplementations(of: header)

        var size: UInt = 0
        guard let base = getsectiondata(header, "__TEXT", "__swift5_replace", &size) else {
            // No section at all. Not "nothing registered": a patch whose every
            // declaration is `@objc` legitimately has none.
            return categories
        }
        guard size >= 8 else { return categories }

        let words = UnsafeRawPointer(base)
        let numScopes = Int(words.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard numScopes > 0 else { return categories }
        guard size >= UInt(8 + numScopes * 8) else { return nil }

        // Every address below is derived from bytes read out of the image, so
        // every one is checked against the image's own mapped segments before
        // it is dereferenced.
        //
        // The layout this reader follows is measured rather than documented, so
        // a toolchain that changes it can produce a `relative` that points
        // nowhere. An unchecked dereference of that is EXC_BAD_ACCESS inside
        // the application, on every save, in the one process this tool exists
        // to keep alive.
        //
        // Measured, and it narrows the risk rather than removing it: five
        // corrupted sections were built and loaded, and four of them killed the
        // process inside `dlopen` -- the Swift runtime reads this same section
        // to bind replacements, and it gets there first. Only a pointer landing
        // just outside the image survived that far, and this check is what
        // stopped it. What remains is a layout that is *different but valid*,
        // where the Swift runtime is content and these offsets read the wrong
        // field; that produces a wrong count rather than a crash, which is why
        // the count is treated as evidence and not as proof.
        let mapped = segments(of: header)
        var total = 0
        for index in 0..<numScopes {
            let entry = words.advanced(by: 8 + index * 8)
            let relative = entry.loadUnaligned(as: Int32.self)
            guard relative != 0 else { continue }

            // A RelativeIndirectablePointer stores "indirect" in the low bit.
            let indirect = relative & 1 == 1
            let target = entry.advanced(by: Int(relative & ~1))

            let scope: UnsafeRawPointer
            if indirect {
                guard mapped.contains(target, bytes: MemoryLayout<UInt>.size),
                      let loaded = UnsafeRawPointer(bitPattern: target.loadUnaligned(as: UInt.self))
                else { return nil }
                scope = loaded
            } else {
                scope = target
            }

            // flags, then numReplacements.
            guard mapped.contains(scope, bytes: 8) else { return nil }
            total += Int(scope.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        return total + categories
    }

    /// How many method bodies the image's Objective-C categories contribute.
    ///
    /// Implementations, not entries. Measured: replacing one `@objc` method
    /// emits a category with *two* method entries -- the replaced selector and
    /// the replacement's own Swift-derived one -- sharing a single `imp`.
    /// Counting entries reported two replacements for one edited declaration,
    /// which reads as "the image did more than was asked" and left every UIKit
    /// lifecycle reload unverified. Distinct `imp` values answer the question
    /// that is actually being asked: how many bodies arrived.
    ///
    /// This is weaker evidence than the Swift section, and deliberately so. A
    /// category method whose selector the class already has replaces it; one
    /// it does not have is added, and nothing readable from the image tells
    /// the two apart. It counts contributions rather than proving
    /// replacements -- the same standing the Swift count has, which also says
    /// what the image declared rather than what the runtime bound.
    ///
    /// Layout, from objc4. Anything unreadable contributes nothing rather than
    /// a wrong number; an undercount is reported as "not verified" and a
    /// session is not worth ending over a section this reader misread.
    ///
    /// ```text
    /// __objc_catlist  array of pointers to category_t
    /// category_t      0: name  8: cls  16: instanceMethods  24: classMethods
    /// method_list_t   0: entsizeAndFlags  4: count  8: entries
    ///                 bit 0x8000_0000 of the first word means the small form
    /// method_t        big   (24 bytes)  0: SEL  8: types  16: IMP
    ///                 small (12 bytes)  0/4/8: int32 each relative to itself
    /// ```
    private static func categoryImplementations(of header: UnsafePointer<mach_header_64>) -> Int {
        var size: UInt = 0
        var base = getsectiondata(header, "__DATA_CONST", "__objc_catlist", &size)
        if base == nil {
            // Anything built without the read-only data segment puts it in
            // plain __DATA.
            base = getsectiondata(header, "__DATA", "__objc_catlist", &size)
        }
        guard let base, size >= 8 else { return 0 }

        let mapped = segments(of: header)
        let pointerSize = MemoryLayout<UInt>.size
        let list = UnsafeRawPointer(base)
        var selectorsPerImplementation: [UInt: Int] = [:]

        for index in 0..<(Int(size) / pointerSize) {
            let slot = list.advanced(by: index * pointerSize)
            guard mapped.contains(slot, bytes: pointerSize),
                  let category = UnsafeRawPointer(bitPattern: slot.loadUnaligned(as: UInt.self)),
                  mapped.contains(category, bytes: 32)
            else { continue }

            // Instance methods at 16, class methods at 24. Either may be null.
            for offset in [16, 24] {
                guard let methods = UnsafeRawPointer(
                        bitPattern: category.loadUnaligned(fromByteOffset: offset, as: UInt.self)),
                      mapped.contains(methods, bytes: 8)
                else { continue }
                collect(from: methods, mapped: mapped, into: &selectorsPerImplementation)
            }
        }
        // Two or more selectors on one implementation means that
        // implementation replaced something. One means it added something.
        return selectorsPerImplementation.values.count { $0 >= 2 }
    }

    private static func collect(from methods: UnsafeRawPointer, mapped: MappedRanges,
                                into selectorsPerImplementation: inout [UInt: Int]) {
        let entsizeAndFlags = methods.loadUnaligned(as: UInt32.self)
        let count = Int(methods.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let small = entsizeAndFlags & 0x8000_0000 != 0
        let entsize = Int(entsizeAndFlags & 0xFFFC)
        guard count > 0, entsize >= (small ? 12 : 24) else { return }

        for index in 0..<count {
            let entry = methods.advanced(by: 8 + index * entsize)
            guard mapped.contains(entry, bytes: entsize) else { return }
            let implementation: UInt
            if small {
                // Each field is an int32 relative to its own address.
                let field = entry.advanced(by: 8)
                let relative = Int(field.loadUnaligned(as: Int32.self))
                implementation = UInt(bitPattern: field.advanced(by: relative))
            } else {
                implementation = entry.loadUnaligned(fromByteOffset: 16, as: UInt.self)
            }
            selectorsPerImplementation[implementation, default: 0] += 1
        }
    }

    /// The address ranges an image occupies, so a computed pointer can be
    /// checked before it is followed.
    ///
    /// The slide comes from the difference between where `__TEXT` says it
    /// wanted to be and where the header actually is, which is the standard way
    /// to recover it from a header alone.
    private static func segments(of header: UnsafePointer<mach_header_64>) -> MappedRanges {
        var ranges: [(start: UInt, end: UInt)] = []
        var slide: UInt?
        let headerAddress = UInt(bitPattern: UnsafeRawPointer(header))

        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            guard command.cmdsize > 0 else { break }
            if command.cmd == LC_SEGMENT_64 {
                let segment = cursor.loadUnaligned(as: segment_command_64.self)
                if slide == nil, withUnsafeBytes(of: segment.segname, { $0.starts(with: Array("__TEXT".utf8)) }) {
                    slide = headerAddress &- UInt(segment.vmaddr)
                }
                if let slide, segment.vmsize > 0 {
                    let start = UInt(segment.vmaddr) &+ slide
                    ranges.append((start, start &+ UInt(segment.vmsize)))
                }
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return MappedRanges(ranges: ranges)
    }

    struct MappedRanges {
        let ranges: [(start: UInt, end: UInt)]

        func contains(_ pointer: UnsafeRawPointer, bytes: Int) -> Bool {
            let start = UInt(bitPattern: pointer)
            let (end, overflowed) = start.addingReportingOverflow(UInt(bytes))
            guard !overflowed else { return false }
            return ranges.contains { start >= $0.start && end <= $0.end }
        }
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
