import Foundation

struct TIFFHeaderInfo {
    let byteOrder: TIFFByteOrder
    let firstIFDOffset: UInt32
}

enum TIFFHeaderParser {
    static func read(
        reader: BoundedReader,
        at absoluteOffset: Int,
        regionEnd: Int
    ) throws -> TIFFHeaderInfo {
        guard absoluteOffset >= 0, absoluteOffset <= regionEnd else {
            throw ParseFailure.outOfBounds
        }
        guard regionEnd - absoluteOffset >= 8 else {
            throw ParseFailure.truncated
        }
        let header = try reader.read(at: absoluteOffset, count: 8)
        let byteOrder: TIFFByteOrder
        switch (header[0], header[1]) {
        case (0x49, 0x49):
            byteOrder = .littleEndian
        case (0x4D, 0x4D):
            byteOrder = .bigEndian
        default:
            throw ParseFailure.unsupported
        }

        let magic: UInt16
        switch byteOrder {
        case .littleEndian:
            magic = UInt16(header[2]) | (UInt16(header[3]) << 8)
        case .bigEndian:
            magic = (UInt16(header[2]) << 8) | UInt16(header[3])
        }
        guard magic == 42 else {
            throw ParseFailure.unsupported
        }

        let firstOffset: UInt32
        switch byteOrder {
        case .littleEndian:
            firstOffset =
                UInt32(header[4])
                | (UInt32(header[5]) << 8)
                | (UInt32(header[6]) << 16)
                | (UInt32(header[7]) << 24)
        case .bigEndian:
            firstOffset =
                (UInt32(header[4]) << 24)
                | (UInt32(header[5]) << 16)
                | (UInt32(header[6]) << 8)
                | UInt32(header[7])
        }

        return TIFFHeaderInfo(byteOrder: byteOrder, firstIFDOffset: firstOffset)
    }
}

/// A TIFF field type's byte width, or nil for a type this implementation does not know.
func tiffTypeSize(_ type: UInt16) -> Int? {
    switch type {
    case 1, 2, 6, 7: return 1
    case 3, 8: return 2
    case 4, 9, 11: return 4
    case 5, 10, 12: return 8
    default: return nil
    }
}

struct TIFFEntry: Sendable, Hashable {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let valueField: [UInt8]
    let entryOffset: Int

    var declaredByteCount: Int? {
        guard let size = tiffTypeSize(type) else {
            return nil
        }
        let (product, overflow) = Int(count).multipliedReportingOverflow(by: size)
        return overflow ? nil : product
    }
}

struct TIFFEntryIndex {
    let entries: [TIFFEntry]
    let duplicateTags: Set<UInt16>

    init(entries: [TIFFEntry]) {
        self.entries = entries
        var counts: [UInt16: Int] = [:]
        for entry in entries {
            counts[entry.tag, default: 0] += 1
        }
        self.duplicateTags = Set(counts.filter { $0.value > 1 }.keys)
    }

    func uniqueEntry(tag: UInt16) -> TIFFEntry? {
        guard !duplicateTags.contains(tag) else { return nil }
        return entries.first { $0.tag == tag }
    }
}

/// A TIFF context. `base` is the offset origin used by out-of-line values.
/// `regionEnd` bounds every value read, so a HIF Exif item or MakerNote cannot
/// escape its containing structure.
struct TIFFContext {
    let reader: BoundedReader
    let base: Int
    let regionEnd: Int
    let byteOrder: TIFFByteOrder

    func absolute(relativeOffset: UInt32) throws -> Int {
        guard base >= 0, base <= regionEnd else {
            throw ParseFailure.outOfBounds
        }
        let available = regionEnd - base
        guard Int(relativeOffset) <= available else {
            throw ParseFailure.outOfBounds
        }
        return base + Int(relativeOffset)
    }

    func read(relativeOffset: UInt32, count: Int) throws -> [UInt8] {
        let absoluteOffset = try absolute(relativeOffset: relativeOffset)
        guard count >= 0, count <= regionEnd - absoluteOffset else {
            throw ParseFailure.outOfBounds
        }
        return try reader.read(at: absoluteOffset, count: count)
    }

    func read(atAbsolute absoluteOffset: Int, count: Int) throws -> [UInt8] {
        guard absoluteOffset >= 0, absoluteOffset <= regionEnd,
            count >= 0, count <= regionEnd - absoluteOffset
        else {
            throw ParseFailure.outOfBounds
        }
        return try reader.read(at: absoluteOffset, count: count)
    }

    func valueOffset(for entry: TIFFEntry) throws -> Int {
        guard let byteCount = entry.declaredByteCount else {
            throw ParseFailure.unsupported
        }
        if byteCount <= 4 {
            return entry.entryOffset + 8
        }
        let offset = decodeUInt32(entry.valueField)
        return try absolute(relativeOffset: offset)
    }

    func readValue(of entry: TIFFEntry) throws -> [UInt8] {
        guard let byteCount = entry.declaredByteCount else {
            throw ParseFailure.unsupported
        }
        let offset = try valueOffset(for: entry)
        guard byteCount <= regionEnd - offset else {
            throw ParseFailure.outOfBounds
        }
        return try read(atAbsolute: offset, count: byteCount)
    }

    func readBytes(of entry: TIFFEntry) throws -> [UInt8] {
        try readValue(of: entry)
    }

    func readASCII(of entry: TIFFEntry, maximumBytes: Int = 1024) throws -> String? {
        guard entry.type == 2 else { return nil }
        guard entry.count <= UInt32(maximumBytes) else { return nil }
        let bytes = try readValue(of: entry)
        let terminated = bytes.prefix { $0 != 0 }
        guard !terminated.isEmpty else { return "" }
        let string =
            String(bytes: terminated, encoding: .utf8)
            ?? String(bytes: terminated, encoding: .isoLatin1)
        return string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readUnsignedValues(of entry: TIFFEntry) throws -> [UInt64]? {
        let bytes = try readValue(of: entry)
        switch entry.type {
        case 1:
            return bytes.map(UInt64.init)
        case 3:
            guard bytes.count % 2 == 0 else { throw ParseFailure.truncated }
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                switch byteOrder {
                case .littleEndian:
                    return UInt64(bytes[index]) | (UInt64(bytes[index + 1]) << 8)
                case .bigEndian:
                    return (UInt64(bytes[index]) << 8) | UInt64(bytes[index + 1])
                }
            }
        case 4:
            guard bytes.count % 4 == 0 else { throw ParseFailure.truncated }
            return stride(from: 0, to: bytes.count, by: 4).map { index in
                switch byteOrder {
                case .littleEndian:
                    return UInt64(bytes[index])
                        | (UInt64(bytes[index + 1]) << 8)
                        | (UInt64(bytes[index + 2]) << 16)
                        | (UInt64(bytes[index + 3]) << 24)
                case .bigEndian:
                    return (UInt64(bytes[index]) << 24)
                        | (UInt64(bytes[index + 1]) << 16)
                        | (UInt64(bytes[index + 2]) << 8)
                        | UInt64(bytes[index + 3])
                }
            }
        case 8:
            guard bytes.count % 2 == 0 else { throw ParseFailure.truncated }
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                let raw: UInt16
                switch byteOrder {
                case .littleEndian:
                    raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                case .bigEndian:
                    raw = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                }
                return UInt64(Int64(Int16(bitPattern: raw)))
            }
        case 9:
            guard bytes.count % 4 == 0 else { throw ParseFailure.truncated }
            return stride(from: 0, to: bytes.count, by: 4).map { index in
                let raw: UInt32
                switch byteOrder {
                case .littleEndian:
                    raw =
                        UInt32(bytes[index])
                        | (UInt32(bytes[index + 1]) << 8)
                        | (UInt32(bytes[index + 2]) << 16)
                        | (UInt32(bytes[index + 3]) << 24)
                case .bigEndian:
                    raw =
                        (UInt32(bytes[index]) << 24)
                        | (UInt32(bytes[index + 1]) << 16)
                        | (UInt32(bytes[index + 2]) << 8)
                        | UInt32(bytes[index + 3])
                }
                return UInt64(Int64(Int32(bitPattern: raw)))
            }
        default:
            return nil
        }
    }

    func readRationals(of entry: TIFFEntry) throws -> [RationalValue]? {
        guard entry.type == 5 || entry.type == 10 else { return nil }
        let bytes = try readValue(of: entry)
        guard bytes.count % 8 == 0 else { throw ParseFailure.truncated }
        var values: [RationalValue] = []
        values.reserveCapacity(bytes.count / 8)
        for index in stride(from: 0, to: bytes.count, by: 8) {
            let first = try decodeUInt32(bytes, at: index)
            let second = try decodeUInt32(bytes, at: index + 4)
            if entry.type == 5 {
                values.append(
                    RationalValue(numerator: Int64(first), denominator: Int64(second))
                )
            } else {
                values.append(
                    RationalValue(
                        numerator: Int64(Int32(bitPattern: first)),
                        denominator: Int64(Int32(bitPattern: second))
                    )
                )
            }
        }
        return values
    }

    func singleUnsignedValue(of entry: TIFFEntry) throws -> UInt64? {
        guard entry.count == 1 else { return nil }
        guard let values = try readUnsignedValues(of: entry), values.count == 1 else {
            return nil
        }
        return values[0]
    }

    func singleByte(of entry: TIFFEntry) throws -> UInt8? {
        guard entry.count == 1, entry.type == 1 || entry.type == 7 else { return nil }
        let bytes = try readValue(of: entry)
        return bytes.first
    }

    private func decodeUInt32(_ bytes: [UInt8]) -> UInt32 {
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        case .bigEndian:
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
    }

    private func decodeUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw ParseFailure.truncated
        }
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        case .bigEndian:
            return (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }
    }
}

enum TIFFDirectoryParser {
    static func parse(
        reader: BoundedReader,
        atAbsolute directoryOffset: Int,
        context: TIFFContext,
        limits: FocusMetadataReader.Limits,
        visited: inout Set<Int>,
        depth: Int,
        tableEnd: Int? = nil
    ) throws -> TIFFEntryIndex {
        guard depth <= limits.maximumIFDDepth else {
            throw ParseFailure.limitExceeded
        }
        let tableLimit = min(tableEnd ?? context.regionEnd, context.regionEnd)
        guard directoryOffset >= 0, directoryOffset <= tableLimit else {
            throw ParseFailure.outOfBounds
        }
        guard !visited.contains(directoryOffset) else {
            throw ParseFailure.invalidIFD
        }
        visited.insert(directoryOffset)
        guard tableLimit - directoryOffset >= 2 else {
            throw ParseFailure.truncated
        }

        let count = try reader.u16(at: directoryOffset, byteOrder: context.byteOrder)
        guard count <= UInt32(limits.maximumIFDEntries) else {
            throw ParseFailure.limitExceeded
        }
        let entryBytes = Int(count) * 12
        guard entryBytes <= tableLimit - directoryOffset - 2 else {
            throw ParseFailure.truncated
        }
        let table = try reader.read(at: directoryOffset + 2, count: entryBytes)
        var entries: [TIFFEntry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let base = index * 12
            let tag = readUInt16(table, at: base, byteOrder: context.byteOrder)
            let type = readUInt16(table, at: base + 2, byteOrder: context.byteOrder)
            let valueCount = readUInt32(table, at: base + 4, byteOrder: context.byteOrder)
            let valueField = Array(table[(base + 8)..<(base + 12)])
            entries.append(
                TIFFEntry(
                    tag: tag,
                    type: type,
                    count: valueCount,
                    valueField: valueField,
                    entryOffset: directoryOffset + 2 + base
                )
            )
        }
        return TIFFEntryIndex(entries: entries)
    }

    private static func readUInt16(
        _ bytes: [UInt8],
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt16 {
        switch byteOrder {
        case .littleEndian:
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        case .bigEndian:
            return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt32 {
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        case .bigEndian:
            return (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }
    }
}
