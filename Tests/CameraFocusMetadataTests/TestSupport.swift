import Foundation

@testable import CameraFocusMetadata

enum TestSupport {
    static func bytes(hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                fatalError("Invalid test hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8], order: TIFFByteOrder) {
        switch order {
        case .littleEndian:
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8(value >> 8))
        case .bigEndian:
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
    }

    static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8], order: TIFFByteOrder) {
        switch order {
        case .littleEndian:
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        case .bigEndian:
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
    }

    static func readUInt16(_ bytes: [UInt8], at offset: Int, order: TIFFByteOrder) -> UInt16 {
        switch order {
        case .littleEndian:
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        case .bigEndian:
            return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int, order: TIFFByteOrder) -> UInt32 {
        switch order {
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

    static func writeUInt16(
        _ value: UInt16,
        to bytes: inout [UInt8],
        at offset: Int,
        order: TIFFByteOrder
    ) {
        let encoded: [UInt8]
        switch order {
        case .littleEndian:
            encoded = [UInt8(value & 0xFF), UInt8(value >> 8)]
        case .bigEndian:
            encoded = [UInt8(value >> 8), UInt8(value & 0xFF)]
        }
        bytes.replaceSubrange(offset..<(offset + 2), with: encoded)
    }

    static func writeUInt32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int,
        order: TIFFByteOrder
    ) {
        let encoded: [UInt8]
        switch order {
        case .littleEndian:
            encoded = [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF),
            ]
        case .bigEndian:
            encoded = [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ]
        }
        bytes.replaceSubrange(offset..<(offset + 4), with: encoded)
    }

    /// An inline-only Sony MakerNote used for container tests that do not need
    /// a focus hint.
    static func sonyMakerNote(
        mode: UInt8 = 3,
        area: UInt8 = 0,
        prefixed: Bool = false
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        if prefixed {
            bytes.append(contentsOf: Array("SONY DSC ".utf8))
            bytes.append(contentsOf: [0, 0, 0])
        }
        appendUInt16(2, to: &bytes, order: .littleEndian)
        appendUInt16(0x201B, to: &bytes, order: .littleEndian)
        appendUInt16(1, to: &bytes, order: .littleEndian)
        appendUInt32(1, to: &bytes, order: .littleEndian)
        bytes.append(contentsOf: [mode, 0, 0, 0])
        appendUInt16(0x201C, to: &bytes, order: .littleEndian)
        appendUInt16(1, to: &bytes, order: .littleEndian)
        appendUInt32(1, to: &bytes, order: .littleEndian)
        bytes.append(contentsOf: [area, 0, 0, 0])
        return bytes
    }

    static func byteCount(type: UInt16, count: UInt32) -> Int {
        let widths: [UInt16: Int] = [
            1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8,
        ]
        return (widths[type] ?? 0) * Int(count)
    }
}

/// A minimal classic-TIFF metadata container for tests.
struct TestTIFFBuilder {
    struct ExtraEntry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let valueBytes: [UInt8]
    }

    var byteOrder: TIFFByteOrder = .littleEndian
    var make: String? = "SONY"
    var model: String? = "ILCE-1M2"
    var software: String? = nil
    var orientation: UInt16? = nil
    var imageExtent: (Int, Int)? = (80, 60)
    var makerNote: [UInt8]? = nil
    var extraIFD0: [ExtraEntry] = []

    func build() -> [UInt8] {
        var ifd0Specs: [ExtraEntry] = []
        if let make {
            var value = Array(make.utf8)
            value.append(0)
            ifd0Specs.append(
                ExtraEntry(tag: 0x010F, type: 2, count: UInt32(value.count), valueBytes: value)
            )
        }
        if let model {
            var value = Array(model.utf8)
            value.append(0)
            ifd0Specs.append(
                ExtraEntry(tag: 0x0110, type: 2, count: UInt32(value.count), valueBytes: value)
            )
        }
        if let software {
            var value = Array(software.utf8)
            value.append(0)
            ifd0Specs.append(
                ExtraEntry(tag: 0x0131, type: 2, count: UInt32(value.count), valueBytes: value)
            )
        }
        if let orientation {
            var value: [UInt8] = []
            TestSupport.appendUInt16(orientation, to: &value, order: byteOrder)
            ifd0Specs.append(
                ExtraEntry(tag: 0x0112, type: 3, count: 1, valueBytes: value)
            )
        }

        var exifSpecs: [ExtraEntry] = []
        if let imageExtent {
            var width: [UInt8] = []
            TestSupport.appendUInt32(UInt32(imageExtent.0), to: &width, order: byteOrder)
            exifSpecs.append(
                ExtraEntry(tag: 0xA002, type: 4, count: 1, valueBytes: width)
            )
            var height: [UInt8] = []
            TestSupport.appendUInt32(UInt32(imageExtent.1), to: &height, order: byteOrder)
            exifSpecs.append(
                ExtraEntry(tag: 0xA003, type: 4, count: 1, valueBytes: height)
            )
        }
        if let makerNote {
            exifSpecs.append(
                ExtraEntry(
                    tag: 0x927C,
                    type: 7,
                    count: UInt32(makerNote.count),
                    valueBytes: makerNote
                )
            )
        }
        ifd0Specs.append(contentsOf: extraIFD0)

        let hasExif = !exifSpecs.isEmpty
        if hasExif {
            var pointer: [UInt8] = []
            TestSupport.appendUInt32(0, to: &pointer, order: byteOrder)
            ifd0Specs.append(
                ExtraEntry(tag: 0x8769, type: 4, count: 1, valueBytes: pointer)
            )
        }

        let ifd0TableSize = 2 + ifd0Specs.count * 12 + 4
        let exifOffset = 8 + ifd0TableSize
        let exifTableSize = hasExif ? 2 + exifSpecs.count * 12 + 4 : 0
        var dataStart = exifOffset + exifTableSize

        func allocate(
            _ specs: inout [ExtraEntry],
            data: inout [UInt8],
            offsets: inout [Int: Int]
        ) {
            for index in specs.indices where specs[index].valueBytes.count > 4 {
                offsets[index] = dataStart
                data.append(contentsOf: specs[index].valueBytes)
                dataStart += specs[index].valueBytes.count
            }
        }

        var data: [UInt8] = []
        var ifd0Offsets: [Int: Int] = [:]
        var exifOffsets: [Int: Int] = [:]
        if hasExif, let pointerIndex = ifd0Specs.firstIndex(where: { $0.tag == 0x8769 }) {
            var pointer: [UInt8] = []
            TestSupport.appendUInt32(UInt32(exifOffset), to: &pointer, order: byteOrder)
            ifd0Specs[pointerIndex] = ExtraEntry(
                tag: 0x8769,
                type: 4,
                count: 1,
                valueBytes: pointer
            )
        }
        allocate(&ifd0Specs, data: &data, offsets: &ifd0Offsets)
        allocate(&exifSpecs, data: &data, offsets: &exifOffsets)

        var output: [UInt8] = []
        output.append(byteOrder == .littleEndian ? 0x49 : 0x4D)
        output.append(byteOrder == .littleEndian ? 0x49 : 0x4D)
        TestSupport.appendUInt16(42, to: &output, order: byteOrder)
        TestSupport.appendUInt32(8, to: &output, order: byteOrder)

        func writeTable(
            _ specs: [ExtraEntry],
            offsets: [Int: Int],
            into bytes: inout [UInt8]
        ) {
            TestSupport.appendUInt16(UInt16(specs.count), to: &bytes, order: byteOrder)
            for (index, spec) in specs.enumerated() {
                TestSupport.appendUInt16(spec.tag, to: &bytes, order: byteOrder)
                TestSupport.appendUInt16(spec.type, to: &bytes, order: byteOrder)
                TestSupport.appendUInt32(spec.count, to: &bytes, order: byteOrder)
                if spec.valueBytes.count <= 4 {
                    var inline = spec.valueBytes
                    inline.append(contentsOf: Array(repeating: 0, count: 4 - inline.count))
                    bytes.append(contentsOf: inline)
                } else {
                    TestSupport.appendUInt32(
                        UInt32(offsets[index] ?? 0),
                        to: &bytes,
                        order: byteOrder
                    )
                }
            }
            TestSupport.appendUInt32(0, to: &bytes, order: byteOrder)
        }

        writeTable(ifd0Specs, offsets: ifd0Offsets, into: &output)
        if hasExif {
            writeTable(exifSpecs, offsets: exifOffsets, into: &output)
        }
        output.append(contentsOf: data)
        return output
    }
}

/// A minimal HEIF/ISO-BMFF container for tests.
struct TestHEIFBuilder {
    struct Property {
        let type: String
        let payload: [UInt8]
    }

    var exifTIFF: [UInt8]
    var primaryItemID: UInt32 = 30
    var exifItemID: UInt32 = 14
    var width: Int = 80
    var height: Int = 60
    var irotPayload: UInt8? = 1
    var extraProperties: [Property] = []
    var primaryAssociations: [Int]? = nil
    var additionalAssociations: [(item: UInt32, indices: [Int])] = []
    var includeCDSC = true
    var cdscTargets: [UInt32]? = nil
    var displacement: UInt32 = 6
    var extentOverride: (offset: UInt32, length: UInt32)? = nil
    var extentCount: Int = 1
    var secondExtent: (offset: UInt32, length: UInt32)? = nil
    var baseOffset: UInt32 = 0
    var baseOffsetSize: Int = 0
    var constructionMethod: UInt8 = 0
    var dataReferenceIndex: UInt16 = 0
    var itemCountOverride: Int? = nil

    func build() -> [UInt8] {
        let ispe = Property(
            type: "ispe",
            payload: fullBoxPayload(
                version: 0,
                flags: 0,
                TestSupport.bytes(hex: String(format: "%08x%08x", width, height))
            )
        )
        var properties: [Property] = [ispe]
        if let irotPayload {
            properties.append(Property(type: "irot", payload: [irotPayload]))
        }
        properties.append(contentsOf: extraProperties)

        let exifPayload = exifItemPayload()
        var containerOffset = 4096
        let associations = primaryAssociations ?? Array(1...properties.count)
        var meta = buildMeta(
            properties: properties,
            exifPayloadLength: UInt32(extentOverride?.length ?? UInt32(exifPayload.count)),
            exifOffset: extentOverride?.offset ?? UInt32(containerOffset + 8),
            primaryAssociations: associations
        )

        var output = box("ftyp", ftypPayload())
        output.append(contentsOf: meta)
        if output.count + 8 > containerOffset {
            containerOffset = output.count + 32
            meta = buildMeta(
                properties: properties,
                exifPayloadLength: UInt32(extentOverride?.length ?? UInt32(exifPayload.count)),
                exifOffset: extentOverride?.offset ?? UInt32(containerOffset + 8),
                primaryAssociations: associations
            )
            output = box("ftyp", ftypPayload())
            output.append(contentsOf: meta)
        }

        let padding = containerOffset - output.count
        if padding > 8 {
            output.append(contentsOf: box("free", Array(repeating: 0, count: padding - 8)))
        }
        output.append(contentsOf: box("mdat", exifPayload))
        return output
    }

    private func exifItemPayload() -> [UInt8] {
        var payload: [UInt8] = []
        TestSupport.appendUInt32(displacement, to: &payload, order: .bigEndian)
        payload.append(contentsOf: Array("Exif".utf8))
        payload.append(contentsOf: [0, 0])
        payload.append(contentsOf: exifTIFF)
        return payload
    }

    private func ftypPayload() -> [UInt8] {
        var payload = Array("heix".utf8)
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(contentsOf: Array("mif1".utf8))
        payload.append(contentsOf: Array("heix".utf8))
        return payload
    }

    private func buildMeta(
        properties: [Property],
        exifPayloadLength: UInt32,
        exifOffset: UInt32,
        primaryAssociations: [Int]
    ) -> [UInt8] {
        var pitmPayload: [UInt8] = []
        TestSupport.appendUInt16(UInt16(primaryItemID), to: &pitmPayload, order: .bigEndian)
        let pitm = fullBox("pitm", version: 0, flags: 0, payload: pitmPayload)

        var iinfPayload: [UInt8] = []
        TestSupport.appendUInt16(
            UInt16(itemCountOverride ?? 3),
            to: &iinfPayload,
            order: .bigEndian
        )
        iinfPayload.append(contentsOf: infe(itemID: exifItemID, type: "Exif"))
        iinfPayload.append(contentsOf: infe(itemID: primaryItemID, type: "grid"))
        iinfPayload.append(contentsOf: infe(itemID: 31, type: "hvc1"))
        let iinf = fullBox("iinf", version: 0, flags: 0, payload: iinfPayload)

        let iloc = itemLocation(
            exifPayloadLength: exifPayloadLength,
            exifOffset: exifOffset
        )

        var irefPayload: [UInt8] = []
        if includeCDSC {
            var cdscPayload: [UInt8] = []
            TestSupport.appendUInt16(UInt16(exifItemID), to: &cdscPayload, order: .bigEndian)
            let targets = cdscTargets ?? [primaryItemID]
            TestSupport.appendUInt16(UInt16(targets.count), to: &cdscPayload, order: .bigEndian)
            for target in targets {
                TestSupport.appendUInt16(UInt16(target), to: &cdscPayload, order: .bigEndian)
            }
            irefPayload.append(contentsOf: box("cdsc", cdscPayload))
        }
        let iref = fullBox("iref", version: 0, flags: 0, payload: irefPayload)

        var ipcoPayload: [UInt8] = []
        for property in properties {
            ipcoPayload.append(contentsOf: box(property.type, property.payload))
        }
        let ipco = box("ipco", ipcoPayload)

        var ipmaPayload: [UInt8] = []
        TestSupport.appendUInt32(
            1 + UInt32(additionalAssociations.count), to: &ipmaPayload, order: .bigEndian)
        appendIPMAEntry(
            item: primaryItemID,
            associations: primaryAssociations,
            to: &ipmaPayload
        )
        for association in additionalAssociations {
            appendIPMAEntry(
                item: association.item,
                associations: association.indices,
                to: &ipmaPayload
            )
        }
        let ipma = fullBox("ipma", version: 0, flags: 0, payload: ipmaPayload)
        let iprp = box("iprp", ipco + ipma)

        let metaPayload =
            pitm + iinf + iloc + iref + iprp
        return fullBox("meta", version: 0, flags: 0, payload: metaPayload)
    }

    private func infe(itemID: UInt32, type: String) -> [UInt8] {
        var payload: [UInt8] = []
        TestSupport.appendUInt16(UInt16(itemID), to: &payload, order: .bigEndian)
        TestSupport.appendUInt16(0, to: &payload, order: .bigEndian)
        payload.append(contentsOf: Array(type.utf8))
        payload.append(0)
        return fullBox("infe", version: 2, flags: 0, payload: payload)
    }

    private func itemLocation(exifPayloadLength: UInt32, exifOffset: UInt32) -> [UInt8] {
        var payload: [UInt8] = [0x44, UInt8((baseOffsetSize << 4) & 0xF0)]
        TestSupport.appendUInt16(1, to: &payload, order: .bigEndian)
        TestSupport.appendUInt16(UInt16(exifItemID), to: &payload, order: .bigEndian)
        TestSupport.appendUInt16(UInt16(constructionMethod), to: &payload, order: .bigEndian)
        TestSupport.appendUInt16(dataReferenceIndex, to: &payload, order: .bigEndian)
        if baseOffsetSize == 4 {
            TestSupport.appendUInt32(baseOffset, to: &payload, order: .bigEndian)
        }
        TestSupport.appendUInt16(UInt16(extentCount), to: &payload, order: .bigEndian)
        TestSupport.appendUInt32(exifOffset, to: &payload, order: .bigEndian)
        TestSupport.appendUInt32(exifPayloadLength, to: &payload, order: .bigEndian)
        if extentCount > 1, let secondExtent {
            TestSupport.appendUInt32(secondExtent.offset, to: &payload, order: .bigEndian)
            TestSupport.appendUInt32(secondExtent.length, to: &payload, order: .bigEndian)
        }
        return fullBox("iloc", version: 1, flags: 0, payload: payload)
    }

    private func appendIPMAEntry(
        item: UInt32,
        associations: [Int],
        to payload: inout [UInt8]
    ) {
        TestSupport.appendUInt16(UInt16(item), to: &payload, order: .bigEndian)
        payload.append(UInt8(associations.count))
        for index in associations {
            payload.append(UInt8(index & 0x7F))
        }
    }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        TestSupport.appendUInt32(UInt32(8 + payload.count), to: &bytes, order: .bigEndian)
        bytes.append(contentsOf: Array(type.utf8))
        bytes.append(contentsOf: payload)
        return bytes
    }

    private func fullBox(_ type: String, version: UInt8, flags: UInt32, payload: [UInt8]) -> [UInt8] {
        box(type, fullBoxPayload(version: version, flags: flags, payload))
    }

    private func fullBoxPayload(version: UInt8, flags: UInt32, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [version]
        bytes.append(UInt8((flags >> 16) & 0xFF))
        bytes.append(UInt8((flags >> 8) & 0xFF))
        bytes.append(UInt8(flags & 0xFF))
        bytes.append(contentsOf: payload)
        return bytes
    }
}

/// Locates and edits the Sony MakerNote entries in a handoff metadata vector.
struct SonyVectorEditor {
    var bytes: [UInt8]
    let order: TIFFByteOrder
    let makerNoteOffset: Int
    let makerNoteLength: Int
    let makerNoteCountEntryOffset: Int

    init(hex: String) throws {
        let bytes = TestSupport.bytes(hex: hex)
        guard bytes.count >= 8 else { throw EditError.invalid }
        let order: TIFFByteOrder = bytes[0] == 0x49 ? .littleEndian : .bigEndian
        let ifd0 = Int(TestSupport.readUInt32(bytes, at: 4, order: order))
        guard
            let exifEntry = try Self.findEntry(
                in: bytes,
                table: ifd0,
                tag: 0x8769,
                order: order
            )
        else { throw EditError.invalid }
        let exif = Int(TestSupport.readUInt32(bytes, at: exifEntry + 8, order: order))
        guard
            let makerNoteEntry = try Self.findEntry(
                in: bytes,
                table: exif,
                tag: 0x927C,
                order: order
            )
        else { throw EditError.invalid }
        let makerNoteOffset = Int(
            TestSupport.readUInt32(bytes, at: makerNoteEntry + 8, order: order)
        )
        let makerNoteLength = Int(
            TestSupport.readUInt32(bytes, at: makerNoteEntry + 4, order: order)
        )
        self.bytes = bytes
        self.order = order
        self.makerNoteOffset = makerNoteOffset
        self.makerNoteLength = makerNoteLength
        self.makerNoteCountEntryOffset = makerNoteEntry
    }

    func entryOffset(tag: UInt16) throws -> Int {
        let count = Int(
            TestSupport.readUInt16(bytes, at: makerNoteOffset, order: order)
        )
        for index in 0..<count {
            let offset = makerNoteOffset + 2 + index * 12
            if TestSupport.readUInt16(bytes, at: offset, order: order) == tag {
                return offset
            }
        }
        throw EditError.missingTag
    }

    func valueOffset(tag: UInt16) throws -> Int {
        let entry = try entryOffset(tag: tag)
        let type = TestSupport.readUInt16(bytes, at: entry + 2, order: order)
        let count = TestSupport.readUInt32(bytes, at: entry + 4, order: order)
        let size = TestSupport.byteCount(type: type, count: count)
        if size <= 4 {
            return entry + 8
        }
        return Int(TestSupport.readUInt32(bytes, at: entry + 8, order: order))
    }

    mutating func setIFD0Orientation(_ value: UInt16) throws {
        let ifd0 = Int(TestSupport.readUInt32(bytes, at: 4, order: order))
        let count = Int(TestSupport.readUInt16(bytes, at: ifd0, order: order))
        for index in 0..<count {
            let entry = ifd0 + 2 + index * 12
            if TestSupport.readUInt16(bytes, at: entry, order: order) == 0x0112 {
                TestSupport.writeUInt16(value, to: &bytes, at: entry + 8, order: order)
                return
            }
        }
        throw EditError.missingTag
    }

    mutating func setMakerNoteDeclaredLength(_ length: UInt32) {
        TestSupport.writeUInt32(
            length,
            to: &bytes,
            at: makerNoteCountEntryOffset + 4,
            order: order
        )
    }

    mutating func setEntryTag(_ newTag: UInt16, tag: UInt16) throws {
        let entry = try entryOffset(tag: tag)
        TestSupport.writeUInt16(newTag, to: &bytes, at: entry, order: order)
    }

    mutating func setEntryType(_ type: UInt16, tag: UInt16) throws {
        let entry = try entryOffset(tag: tag)
        TestSupport.writeUInt16(type, to: &bytes, at: entry + 2, order: order)
    }

    mutating func setEntryCount(_ count: UInt32, tag: UInt16) throws {
        let entry = try entryOffset(tag: tag)
        TestSupport.writeUInt32(count, to: &bytes, at: entry + 4, order: order)
    }

    mutating func setEntryOffset(_ offset: UInt32, tag: UInt16) throws {
        let entry = try entryOffset(tag: tag)
        TestSupport.writeUInt32(offset, to: &bytes, at: entry + 8, order: order)
    }

    mutating func setWords(_ words: [UInt16], tag: UInt16) throws {
        let offset = try valueOffset(tag: tag)
        for (index, word) in words.enumerated() {
            TestSupport.writeUInt16(
                word,
                to: &bytes,
                at: offset + index * 2,
                order: order
            )
        }
    }

    mutating func setBytes(_ value: [UInt8], tag: UInt16) throws {
        let offset = try valueOffset(tag: tag)
        bytes.replaceSubrange(offset..<(offset + value.count), with: value)
    }

    mutating func appendBytes(_ extra: [UInt8]) {
        bytes.append(contentsOf: extra)
    }

    private static func findEntry(
        in bytes: [UInt8],
        table: Int,
        tag: UInt16,
        order: TIFFByteOrder
    ) throws -> Int? {
        guard table >= 0, table + 2 <= bytes.count else { throw EditError.invalid }
        let count = Int(TestSupport.readUInt16(bytes, at: table, order: order))
        for index in 0..<count {
            let offset = table + 2 + index * 12
            guard offset + 12 <= bytes.count else { throw EditError.invalid }
            if TestSupport.readUInt16(bytes, at: offset, order: order) == tag {
                return offset
            }
        }
        return nil
    }

    enum EditError: Error {
        case invalid
        case missingTag
    }
}
