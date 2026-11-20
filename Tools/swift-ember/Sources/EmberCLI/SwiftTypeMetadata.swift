import Foundation

// Read the in-image Swift ABI records that survive symbol stripping. Each
// architecture's __TEXT segment supplies its own records and relative targets.
enum SwiftTypeMetadata {
    static func containsClass(in image: URL, loadCommands: String, module: String, names: [String]) throws -> Bool {
        let slices = loadCommands.components(separatedBy: "\nLoad command 0\n")
        let fatHeader = slices[0].split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
        let offsets = fatHeader.compactMap { number($0, named: "offset") }
        let sizes = fatHeader.compactMap { number($0, named: "size") }
        let data = try Data(contentsOf: image, options: .mappedIfSafe)
        let sliceBounds = offsets.isEmpty ? [(0, data.count)] : Array(zip(offsets, sizes))
        let invalidLayout = ReleaseDoctor.InspectionError("cannot locate the Mach-O Swift type metadata")
        guard offsets.count == sizes.count, sliceBounds.count == slices.count - 1 else { throw invalidLayout }

        let moduleName = Array(module.utf8) + [0]
        let classNames = names.map { Array($0.utf8) + [0] }
        return try data.withUnsafeBytes { bytes in
            for ((sliceOffset, sliceSize), layout) in zip(sliceBounds, slices.dropFirst()) {
                let lines = layout.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
                guard let types = lines.firstIndex(of: ["sectname", "__swift5_types"]) else { continue }
                // Section offsets are relative to the slice. All the Swift
                // descriptors and names we need are part of __TEXT as well.
                guard let textHeader = lines.firstIndex(of: ["segname", "__TEXT"]),
                      let text = fileRegion(lines.dropFirst(textHeader + 1), offsetKey: "fileoff", sizeKey: "filesize"),
                      let types = fileRegion(lines.dropFirst(types + 1), offsetKey: "offset", sizeKey: "size"),
                      types.size.isMultiple(of: 4), sliceSize <= bytes.count - sliceOffset,
                      text.offset <= sliceSize, text.size <= sliceSize - text.offset,
                      types.offset >= text.offset, types.offset - text.offset <= text.size,
                      types.size <= text.size - (types.offset - text.offset) else { throw invalidLayout }

                let start = sliceOffset + text.offset
                let textBytes = UnsafeRawBufferPointer(rebasing: bytes[start..<(start + text.size)])
                let recordStart = types.offset - text.offset
                let records = recordStart..<(recordStart + types.size)
                if containsClass(in: textBytes, records: records, module: moduleName, names: classNames) {
                    return true
                }
            }
            return false
        }
    }

    private static func fileRegion(
        _ lines: ArraySlice<[Substring]>, offsetKey: String, sizeKey: String
    ) -> (offset: Int, size: Int)? {
        let fields = lines.prefix { $0.first != "Section" && $0.first != "Load" }
        guard let offset = fields.lazy.compactMap({ number($0, named: offsetKey) }).first,
              let size = fields.lazy.compactMap({ number($0, named: sizeKey) }).first else { return nil }
        return (offset, size)
    }

    private static func number(_ fields: [Substring], named key: String) -> Int? {
        guard fields.count == 2, fields[0] == key else { return nil }
        let value = fields[1]
        let number = value.hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
        guard let number, number >= 0 else { return nil }
        return number
    }

    private static func containsClass(
        in text: UnsafeRawBufferPointer, records: Range<Int>, module: [UInt8], names: [[UInt8]]
    ) -> Bool {
        func word(at offset: Int) -> UInt32? {
            guard offset >= 0, offset <= text.count - 4 else { return nil }
            return UInt32(littleEndian: text.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }

        func directTarget(at offset: Int, tagMask: UInt32 = 0) -> Int? {
            guard let value = word(at: offset), value != 0, value & tagMask == 0 else { return nil }
            let (target, overflow) = offset.addingReportingOverflow(Int(Int32(bitPattern: value)))
            return !overflow && (0..<text.count).contains(target) ? target : nil
        }

        // Swift ABI: a type record is a signed relative reference with two
        // tag bits. Local type descriptors and module parents use direct
        // references. The flags' low five bits encode the descriptor kind.
        let kindMask: UInt32 = 0x1f
        let classKind: UInt32 = 0x10
        let moduleKind: UInt32 = 0
        for record in stride(from: records.lowerBound, to: records.upperBound, by: 4) {
            guard let descriptor = directTarget(at: record, tagMask: 0b11), descriptor <= text.count - 12,
                  let flags = word(at: descriptor), flags & kindMask == classKind,
                  let name = directTarget(at: descriptor + 8), names.contains(where: { text[name...].starts(with: $0) }),
                  let parent = directTarget(at: descriptor + 4, tagMask: 0b1), parent <= text.count - 12,
                  let parentFlags = word(at: parent), parentFlags & kindMask == moduleKind,
                  let parentName = directTarget(at: parent + 8), text[parentName...].starts(with: module) else { continue }
            return true
        }
        return false
    }
}
