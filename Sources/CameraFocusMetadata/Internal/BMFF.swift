import Foundation

struct BMFFBox: Sendable, Hashable {
    let type: String
    let boxStart: Int
    let payloadStart: Int
    let end: Int

    var payloadLength: Int { end - payloadStart }
}

enum BMFFParser {
    static func readBoxHeader(
        reader: BoundedReader,
        at offset: Int,
        parentEnd: Int
    ) throws -> BMFFBox {
        guard offset >= 0, parentEnd <= reader.length, offset <= parentEnd else {
            throw ParseFailure.outOfBounds
        }
        guard parentEnd - offset >= 8 else {
            throw ParseFailure.truncated
        }
        let header = try reader.read(at: offset, count: 8)
        let size32 = decodeUInt32(header, at: 0, byteOrder: .bigEndian)
        let typeBytes = Array(header[4..<8])
        let type =
            String(bytes: typeBytes, encoding: .isoLatin1)
            ?? typeBytes.map { String(format: "%02X", $0) }.joined()

        let headerLength: Int
        let boxEnd: Int
        if size32 == 1 {
            guard parentEnd - offset >= 16 else {
                throw ParseFailure.truncated
            }
            let large = try reader.u64(at: offset + 8, byteOrder: .bigEndian)
            guard large <= UInt64(Int.max) else {
                throw ParseFailure.arithmeticOverflow
            }
            headerLength = 16
            boxEnd = try addOffset(offset, Int(large))
        } else if size32 == 0 {
            headerLength = 8
            boxEnd = parentEnd
        } else {
            headerLength = 8
            guard size32 >= 8 else {
                throw ParseFailure.invalidIFD
            }
            boxEnd = try addOffset(offset, Int(size32))
        }

        let payloadStart = try addOffset(offset, headerLength)
        guard boxEnd <= parentEnd, payloadStart <= boxEnd else {
            throw ParseFailure.outOfBounds
        }
        return BMFFBox(
            type: type,
            boxStart: offset,
            payloadStart: payloadStart,
            end: boxEnd
        )
    }

    static func forEachBox(
        reader: BoundedReader,
        start: Int,
        end: Int,
        depth: Int,
        limits: FocusMetadataReader.Limits,
        boxCounter: inout Int,
        body: (BMFFBox) throws -> Void
    ) throws {
        guard depth <= limits.maximumBoxDepth else {
            throw ParseFailure.limitExceeded
        }
        var offset = start
        while offset < end {
            let box = try readBoxHeader(reader: reader, at: offset, parentEnd: end)
            boxCounter += 1
            guard boxCounter <= 100_000 else {
                throw ParseFailure.limitExceeded
            }
            try body(box)
            guard box.end > offset else {
                throw ParseFailure.invalidIFD
            }
            offset = box.end
        }
        guard offset == end else {
            throw ParseFailure.truncated
        }
    }

    static func addOffset(_ base: Int, _ delta: Int) throws -> Int {
        let (sum, overflow) = base.addingReportingOverflow(delta)
        guard !overflow else { throw ParseFailure.arithmeticOverflow }
        return sum
    }

    static func decodeUInt32(
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

struct HEIFItemInfo: Sendable, Hashable {
    let itemID: UInt32
    let itemType: String?
    let name: String?
}

struct HEIFExtent: Sendable, Hashable {
    let offset: UInt64
    let length: UInt64
}

struct HEIFItemLocation: Sendable, Hashable {
    let constructionMethod: UInt8
    let dataReferenceIndex: UInt16
    let baseOffset: UInt64
    let extents: [HEIFExtent]
}

struct HEIFReference: Sendable, Hashable {
    let fromItemID: UInt32
    let type: String
    let toItemIDs: [UInt32]
}

struct HEIFProperty: Sendable, Hashable {
    let index: Int
    let type: String
    let payloadStart: Int
    let payloadEnd: Int
}

struct HEIFAssociation: Sendable, Hashable {
    let essential: Bool
    let propertyIndex: Int
}

struct HEIFMetadata: Sendable, Hashable {
    var primaryItemID: UInt32?
    var items: [UInt32: HEIFItemInfo] = [:]
    var locations: [UInt32: HEIFItemLocation] = [:]
    var references: [HEIFReference] = []
    var properties: [HEIFProperty] = []
    var associations: [UInt32: [HEIFAssociation]] = [:]
}

enum HEIFParser {
    static func parse(
        reader: BoundedReader,
        meta: BMFFBox,
        limits: FocusMetadataReader.Limits
    ) throws -> HEIFMetadata {
        guard meta.payloadLength >= 4 else {
            throw ParseFailure.truncated
        }
        var metadata = HEIFMetadata()
        var boxCounter = 0
        let childrenStart = meta.payloadStart + 4
        try BMFFParser.forEachBox(
            reader: reader,
            start: childrenStart,
            end: meta.end,
            depth: 1,
            limits: limits,
            boxCounter: &boxCounter
        ) { box in
            switch box.type {
            case "pitm":
                let itemID = try parsePrimaryItem(reader: reader, box: box)
                if metadata.primaryItemID != nil {
                    throw ParseFailure.invalidIFD
                }
                metadata.primaryItemID = itemID
            case "iinf":
                let items = try parseItemInfo(reader: reader, box: box, limits: limits)
                for item in items {
                    if metadata.items[item.itemID] != nil {
                        throw ParseFailure.invalidIFD
                    }
                    metadata.items[item.itemID] = item
                }
            case "iloc":
                let locations = try parseItemLocations(reader: reader, box: box, limits: limits)
                for (itemID, location) in locations {
                    if metadata.locations[itemID] != nil {
                        throw ParseFailure.invalidIFD
                    }
                    metadata.locations[itemID] = location
                }
            case "iref":
                metadata.references.append(
                    contentsOf: try parseItemReferences(reader: reader, box: box, limits: limits)
                )
            case "iprp":
                try parseProperties(
                    reader: reader,
                    box: box,
                    limits: limits,
                    metadata: &metadata
                )
            default:
                break
            }
        }
        return metadata
    }

    private static func parsePrimaryItem(
        reader: BoundedReader,
        box: BMFFBox
    ) throws -> UInt32 {
        guard box.payloadLength >= 6 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: box.payloadStart)
        if version == 0 {
            return UInt32(try reader.u16(at: box.payloadStart + 4, byteOrder: .bigEndian))
        }
        guard box.payloadLength >= 8 else {
            throw ParseFailure.truncated
        }
        return try reader.u32(at: box.payloadStart + 4, byteOrder: .bigEndian)
    }

    private static func parseItemInfo(
        reader: BoundedReader,
        box: BMFFBox,
        limits: FocusMetadataReader.Limits
    ) throws -> [HEIFItemInfo] {
        guard box.payloadLength >= 6 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: box.payloadStart)
        let countSize = version == 0 ? 2 : 4
        guard box.payloadLength >= 4 + countSize else {
            throw ParseFailure.truncated
        }
        let count: UInt32
        if countSize == 2 {
            count = UInt32(try reader.u16(at: box.payloadStart + 4, byteOrder: .bigEndian))
        } else {
            count = try reader.u32(at: box.payloadStart + 4, byteOrder: .bigEndian)
        }
        guard count <= UInt32(limits.maximumIFDEntries) else {
            throw ParseFailure.limitExceeded
        }

        var items: [HEIFItemInfo] = []
        items.reserveCapacity(Int(count))
        var innerCounter = 0
        let childrenStart = box.payloadStart + 4 + countSize
        try BMFFParser.forEachBox(
            reader: reader,
            start: childrenStart,
            end: box.end,
            depth: 2,
            limits: limits,
            boxCounter: &innerCounter
        ) { child in
            guard child.type == "infe" else { return }
            guard let item = try parseItemInfoEntry(reader: reader, box: child) else {
                return
            }
            items.append(item)
        }
        guard items.count == Int(count) else {
            throw ParseFailure.invalidIFD
        }
        return items
    }

    private static func parseItemInfoEntry(
        reader: BoundedReader,
        box: BMFFBox
    ) throws -> HEIFItemInfo? {
        guard box.payloadLength >= 8 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: box.payloadStart)
        switch version {
        case 0, 1:
            let itemID = UInt32(try reader.u16(at: box.payloadStart + 4, byteOrder: .bigEndian))
            let name = try readCString(reader: reader, at: box.payloadStart + 8, end: box.end)
            return HEIFItemInfo(itemID: itemID, itemType: nil, name: name)
        case 2:
            guard box.payloadLength >= 12 else {
                throw ParseFailure.truncated
            }
            let itemID = UInt32(try reader.u16(at: box.payloadStart + 4, byteOrder: .bigEndian))
            let type = try readFourCC(reader: reader, at: box.payloadStart + 8)
            let name = try readCString(reader: reader, at: box.payloadStart + 12, end: box.end)
            return HEIFItemInfo(itemID: itemID, itemType: type, name: name)
        case 3:
            guard box.payloadLength >= 14 else {
                throw ParseFailure.truncated
            }
            let itemID = try reader.u32(at: box.payloadStart + 4, byteOrder: .bigEndian)
            let type = try readFourCC(reader: reader, at: box.payloadStart + 10)
            let name = try readCString(reader: reader, at: box.payloadStart + 14, end: box.end)
            return HEIFItemInfo(itemID: itemID, itemType: type, name: name)
        default:
            throw ParseFailure.unsupported
        }
    }

    private static func parseItemLocations(
        reader: BoundedReader,
        box: BMFFBox,
        limits: FocusMetadataReader.Limits
    ) throws -> [UInt32: HEIFItemLocation] {
        var cursor = box.payloadStart
        guard box.payloadLength >= 8 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: cursor)
        guard version <= 2 else {
            throw ParseFailure.unsupported
        }
        cursor += 4
        let sizeByte1 = try reader.u8(at: cursor)
        let sizeByte2 = try reader.u8(at: cursor + 1)
        cursor += 2
        let offsetSize = Int((sizeByte1 >> 4) & 0x0F)
        let lengthSize = Int(sizeByte1 & 0x0F)
        let baseOffsetSize = Int((sizeByte2 >> 4) & 0x0F)
        let indexSize = Int(sizeByte2 & 0x0F)
        for size in [offsetSize, lengthSize, baseOffsetSize, indexSize] where size > 8 {
            throw ParseFailure.unsupported
        }

        let count: UInt32
        if version < 2 {
            guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
            count = UInt32(try reader.u16(at: cursor, byteOrder: .bigEndian))
            cursor += 2
        } else {
            guard cursor + 4 <= box.end else { throw ParseFailure.truncated }
            count = try reader.u32(at: cursor, byteOrder: .bigEndian)
            cursor += 4
        }
        guard count <= UInt32(limits.maximumIFDEntries) else {
            throw ParseFailure.limitExceeded
        }

        var locations: [UInt32: HEIFItemLocation] = [:]
        locations.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            let itemID: UInt32
            if version < 2 {
                guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
                itemID = UInt32(try reader.u16(at: cursor, byteOrder: .bigEndian))
                cursor += 2
            } else {
                guard cursor + 4 <= box.end else { throw ParseFailure.truncated }
                itemID = try reader.u32(at: cursor, byteOrder: .bigEndian)
                cursor += 4
            }
            var constructionMethod: UInt8 = 0
            if version == 1 || version == 2 {
                guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
                let methodField = try reader.u16(at: cursor, byteOrder: .bigEndian)
                constructionMethod = UInt8(methodField & 0x0F)
                cursor += 2
            }
            guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
            let dataReferenceIndex = try reader.u16(at: cursor, byteOrder: .bigEndian)
            cursor += 2
            let baseOffset = try readVariableWidth(
                reader: reader,
                at: &cursor,
                width: baseOffsetSize,
                end: box.end
            )
            guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
            let extentCount = try reader.u16(at: cursor, byteOrder: .bigEndian)
            cursor += 2
            guard extentCount <= 64 else {
                throw ParseFailure.limitExceeded
            }
            var extents: [HEIFExtent] = []
            extents.reserveCapacity(Int(extentCount))
            for _ in 0..<Int(extentCount) {
                if (version == 1 || version == 2) && indexSize > 0 {
                    _ = try readVariableWidth(
                        reader: reader,
                        at: &cursor,
                        width: indexSize,
                        end: box.end
                    )
                }
                let offset = try readVariableWidth(
                    reader: reader,
                    at: &cursor,
                    width: offsetSize,
                    end: box.end
                )
                let length = try readVariableWidth(
                    reader: reader,
                    at: &cursor,
                    width: lengthSize,
                    end: box.end
                )
                extents.append(HEIFExtent(offset: offset, length: length))
            }
            guard locations[itemID] == nil else {
                throw ParseFailure.invalidIFD
            }
            locations[itemID] = HEIFItemLocation(
                constructionMethod: constructionMethod,
                dataReferenceIndex: dataReferenceIndex,
                baseOffset: baseOffset,
                extents: extents
            )
        }
        return locations
    }

    private static func readVariableWidth(
        reader: BoundedReader,
        at cursor: inout Int,
        width: Int,
        end: Int
    ) throws -> UInt64 {
        guard width >= 0, width <= 8 else {
            throw ParseFailure.unsupported
        }
        guard cursor >= 0, cursor <= end, width <= end - cursor else {
            throw ParseFailure.truncated
        }
        if width == 0 { return 0 }
        let bytes = try reader.read(at: cursor, count: width)
        cursor += width
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func parseItemReferences(
        reader: BoundedReader,
        box: BMFFBox,
        limits: FocusMetadataReader.Limits
    ) throws -> [HEIFReference] {
        guard box.payloadLength >= 4 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: box.payloadStart)
        guard version <= 1 else {
            throw ParseFailure.unsupported
        }
        let idSize = version == 0 ? 2 : 4
        var references: [HEIFReference] = []
        var counter = 0
        try BMFFParser.forEachBox(
            reader: reader,
            start: box.payloadStart + 4,
            end: box.end,
            depth: 2,
            limits: limits,
            boxCounter: &counter
        ) { child in
            var cursor = child.payloadStart
            let fromID: UInt32
            if idSize == 2 {
                guard cursor + 2 <= child.end else { throw ParseFailure.truncated }
                fromID = UInt32(try reader.u16(at: cursor, byteOrder: .bigEndian))
                cursor += 2
            } else {
                guard cursor + 4 <= child.end else { throw ParseFailure.truncated }
                fromID = try reader.u32(at: cursor, byteOrder: .bigEndian)
                cursor += 4
            }
            guard cursor + 2 <= child.end else { throw ParseFailure.truncated }
            let count = try reader.u16(at: cursor, byteOrder: .bigEndian)
            cursor += 2
            guard count <= 4096 else { throw ParseFailure.limitExceeded }
            guard cursor + Int(count) * idSize <= child.end else {
                throw ParseFailure.truncated
            }
            var toItems: [UInt32] = []
            toItems.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                if idSize == 2 {
                    toItems.append(UInt32(try reader.u16(at: cursor, byteOrder: .bigEndian)))
                    cursor += 2
                } else {
                    toItems.append(try reader.u32(at: cursor, byteOrder: .bigEndian))
                    cursor += 4
                }
            }
            references.append(
                HEIFReference(fromItemID: fromID, type: child.type, toItemIDs: toItems)
            )
        }
        guard references.count <= 4096 else {
            throw ParseFailure.limitExceeded
        }
        return references
    }

    private static func parseProperties(
        reader: BoundedReader,
        box: BMFFBox,
        limits: FocusMetadataReader.Limits,
        metadata: inout HEIFMetadata
    ) throws {
        guard box.payloadLength >= 1 else {
            throw ParseFailure.truncated
        }
        var counter = 0
        try BMFFParser.forEachBox(
            reader: reader,
            start: box.payloadStart,
            end: box.end,
            depth: 2,
            limits: limits,
            boxCounter: &counter
        ) { child in
            switch child.type {
            case "ipco":
                var propertyCounter = 0
                try BMFFParser.forEachBox(
                    reader: reader,
                    start: child.payloadStart,
                    end: child.end,
                    depth: 3,
                    limits: limits,
                    boxCounter: &propertyCounter
                ) { propertyBox in
                    metadata.properties.append(
                        HEIFProperty(
                            index: metadata.properties.count + 1,
                            type: propertyBox.type,
                            payloadStart: propertyBox.payloadStart,
                            payloadEnd: propertyBox.end
                        )
                    )
                }
            case "ipma":
                try parsePropertyAssociations(
                    reader: reader,
                    box: child,
                    limits: limits,
                    metadata: &metadata
                )
            default:
                break
            }
        }
    }

    private static func parsePropertyAssociations(
        reader: BoundedReader,
        box: BMFFBox,
        limits: FocusMetadataReader.Limits,
        metadata: inout HEIFMetadata
    ) throws {
        guard box.payloadLength >= 8 else {
            throw ParseFailure.truncated
        }
        let version = try reader.u8(at: box.payloadStart)
        guard version <= 1 else {
            throw ParseFailure.unsupported
        }
        let flags = try reader.read(at: box.payloadStart + 1, count: 3)
        let wideIndexes = (flags[2] & 0x01) != 0
        let itemCount = try reader.u32(at: box.payloadStart + 4, byteOrder: .bigEndian)
        guard itemCount <= UInt32(limits.maximumIFDEntries) else {
            throw ParseFailure.limitExceeded
        }
        var cursor = box.payloadStart + 8
        for _ in 0..<Int(itemCount) {
            let itemID: UInt32
            if version == 0 {
                guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
                itemID = UInt32(try reader.u16(at: cursor, byteOrder: .bigEndian))
                cursor += 2
            } else {
                guard cursor + 4 <= box.end else { throw ParseFailure.truncated }
                itemID = try reader.u32(at: cursor, byteOrder: .bigEndian)
                cursor += 4
            }
            guard cursor + 1 <= box.end else { throw ParseFailure.truncated }
            let associationCount = Int(try reader.u8(at: cursor))
            cursor += 1
            guard associationCount <= 256 else {
                throw ParseFailure.limitExceeded
            }
            var associations: [HEIFAssociation] = []
            associations.reserveCapacity(associationCount)
            for _ in 0..<associationCount {
                if wideIndexes {
                    guard cursor + 2 <= box.end else { throw ParseFailure.truncated }
                    let first = try reader.u8(at: cursor)
                    let second = try reader.u8(at: cursor + 1)
                    cursor += 2
                    associations.append(
                        HEIFAssociation(
                            essential: (first & 0x80) != 0,
                            propertyIndex: Int(first & 0x7F) << 8 | Int(second)
                        )
                    )
                } else {
                    guard cursor + 1 <= box.end else { throw ParseFailure.truncated }
                    let value = try reader.u8(at: cursor)
                    cursor += 1
                    associations.append(
                        HEIFAssociation(
                            essential: (value & 0x80) != 0,
                            propertyIndex: Int(value & 0x7F)
                        )
                    )
                }
            }
            guard metadata.associations[itemID] == nil else {
                throw ParseFailure.invalidIFD
            }
            metadata.associations[itemID] = associations
        }
    }

    private static func readCString(
        reader: BoundedReader,
        at start: Int,
        end: Int
    ) throws -> String? {
        guard start >= 0, start <= end else { return nil }
        var bytes: [UInt8] = []
        var cursor = start
        let limit = min(end, start + 256)
        while cursor < limit {
            let byte = try reader.u8(at: cursor)
            if byte == 0 { break }
            bytes.append(byte)
            cursor += 1
        }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func readFourCC(
        reader: BoundedReader,
        at offset: Int
    ) throws -> String {
        let bytes = try reader.read(at: offset, count: 4)
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }
}
