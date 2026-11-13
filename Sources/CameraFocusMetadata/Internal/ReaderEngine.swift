import Foundation

final class ReaderEngine {
    private let limits: FocusMetadataReader.Limits

    init(limits: FocusMetadataReader.Limits) {
        self.limits = limits
    }

    func read(source: ByteSource) throws -> FocusMetadataReport {
        let reader = BoundedReader(source: source, limits: limits)
        let headCount = min(16, reader.length)
        guard headCount >= 2 else {
            throw MetadataError(
                kind: .unrecognizedContainer,
                detail: "The input is too short to identify a metadata container."
            )
        }
        let head: [UInt8]
        do {
            head = try reader.read(at: 0, count: headCount)
        } catch {
            throw MetadataError(
                kind: .cannotReadFile,
                detail: "The input header could not be read."
            )
        }

        if isTIFFSignature(head) {
            guard head.count >= 4 else {
                return malformedReport(
                    kind: .classicTIFF,
                    issue: .truncatedData,
                    context: "TIFF header"
                )
            }
            let byteOrder: TIFFByteOrder = head[0] == 0x49 ? .littleEndian : .bigEndian
            let magic = readUInt16(head, at: 2, byteOrder: byteOrder)
            switch magic {
            case 42:
                return readClassicTIFF(reader: reader)
            case 85 where byteOrder == .littleEndian:
                return readPanasonicRW2(reader: reader)
            case 0x4F52:
                return readOlympusORF(reader: reader, byteOrder: byteOrder)
            default:
                return malformedReport(
                    kind: .classicTIFF,
                    byteOrder: byteOrder,
                    issue: .unsupportedValueLayout,
                    context: "TIFF header magic"
                )
            }
        }

        if isRAFSIgnature(head) {
            return readFujifilmRAF(reader: reader)
        }

        if head.count >= 12, ascii(head, range: 4..<8) == "ftyp" {
            let brand = ascii(head, range: 8..<12) ?? ""
            if brand == "crx " {
                return readCanonCR3(reader: reader)
            }
            return readHEIF(reader: reader)
        }

        if head[0] == 0xFF, head[1] == 0xD8 {
            return readJPEG(reader: reader)
        }

        throw MetadataError(
            kind: .unrecognizedContainer,
            detail: "The input did not match a supported TIFF, HEIF, CR3, RAF, RW2, ORF, or JPEG entry point."
        )
    }

    private func readClassicTIFF(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .classicTIFF,
                byteOrder: nil,
                makerNoteFlavor: nil,
                entryPoint: .classicTIFFIFD0
            )
        )
        do {
            let header = try TIFFHeaderParser.read(
                reader: reader,
                at: 0,
                regionEnd: reader.length
            )
            TIFFMetadataExtractor.extract(
                reader: reader,
                options: TIFFExtractionOptions(
                    containerKind: .classicTIFF,
                    entryPoint: .classicTIFFIFD0,
                    base: 0,
                    regionEnd: reader.length,
                    byteOrder: header.byteOrder,
                    firstIFDOffset: header.firstIFDOffset
                ),
                builder: builder,
                limits: limits
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "TIFF header")
            builder.focusPathMalformed = true
        } catch {
            builder.focusPathMalformed = true
        }
        return builder.makeReport()
    }

    private func readOlympusORF(
        reader: BoundedReader,
        byteOrder: TIFFByteOrder
    ) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .olympusORF,
                byteOrder: byteOrder,
                makerNoteFlavor: nil,
                entryPoint: .classicTIFFIFD0
            )
        )
        do {
            let header = try reader.read(at: 0, count: 8)
            let firstOffset = readUInt32(header, at: 4, byteOrder: byteOrder)
            TIFFMetadataExtractor.extract(
                reader: reader,
                options: TIFFExtractionOptions(
                    containerKind: .olympusORF,
                    entryPoint: .classicTIFFIFD0,
                    base: 0,
                    regionEnd: reader.length,
                    byteOrder: byteOrder,
                    firstIFDOffset: firstOffset
                ),
                builder: builder,
                limits: limits
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "ORF header")
            builder.focusPathMalformed = true
        } catch {
            builder.focusPathMalformed = true
        }
        return builder.makeReport()
    }

    private func readPanasonicRW2(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .panasonicRW2,
                byteOrder: .littleEndian,
                makerNoteFlavor: nil,
                entryPoint: .classicTIFFIFD0
            )
        )
        let context = TIFFContext(
            reader: reader,
            base: 0,
            regionEnd: reader.length,
            byteOrder: .littleEndian
        )
        var visited: Set<Int> = []
        let index: TIFFEntryIndex
        do {
            let header = try reader.read(at: 0, count: 8)
            let firstOffset = readUInt32(header, at: 4, byteOrder: .littleEndian)
            let absolute = try context.absolute(relativeOffset: firstOffset)
            index = try TIFFDirectoryParser.parse(
                reader: reader,
                atAbsolute: absolute,
                context: context,
                limits: limits,
                visited: &visited,
                depth: 0
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "RW2 IFD0")
            builder.focusPathMalformed = true
            return builder.makeReport()
        } catch {
            builder.focusPathMalformed = true
            return builder.makeReport()
        }

        let make = readCameraASCII(index, tag: 0x010F, context: context, builder: builder)
        let model = readCameraASCII(index, tag: 0x0110, context: context, builder: builder)
        let software = readCameraASCII(index, tag: 0x0131, context: context, builder: builder)
        if make != nil || model != nil || software != nil {
            builder.camera = CameraIdentity(
                vendor: .panasonic,
                make: make,
                model: model,
                recordedSoftware: software
            )
        }

        guard let entry = index.uniqueEntry(tag: 0x002E) else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedVendorFocusLayout,
                context: "RW2 embedded JPEG",
                detail: "The embedded-JPEG tag was absent."
            )
            return builder.makeReport()
        }
        guard entry.type == 7,
            let byteCount = entry.declaredByteCount,
            byteCount > 0
        else {
            builder.focusPathMalformed = true
            builder.addIssue(
                .unexpectedFieldShape,
                context: "RW2 tag 0x002e"
            )
            return builder.makeReport()
        }
        do {
            let jpegOffset = try context.valueOffset(for: entry)
            guard jpegOffset >= 0, jpegOffset < reader.length,
                byteCount <= reader.length - jpegOffset
            else {
                builder.focusPathMalformed = true
                builder.addIssue(.offsetOutOfBounds, context: "RW2 embedded JPEG")
                return builder.makeReport()
            }
            let jpegEnd = jpegOffset + byteCount
            _ = extractEmbeddedJPEG(
                reader: reader,
                jpegStart: jpegOffset,
                jpegEnd: jpegEnd,
                kind: .panasonicRW2,
                entryPoint: .classicTIFFIFD0,
                builder: builder
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "RW2 embedded JPEG")
            builder.focusPathMalformed = true
        } catch {
            builder.focusPathMalformed = true
        }
        return builder.makeReport()
    }

    private func readFujifilmRAF(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .fujifilmRAF,
                byteOrder: nil,
                makerNoteFlavor: nil,
                entryPoint: .embeddedJPEGExif(segmentOffset: 0)
            )
        )
        guard reader.length >= 92 else {
            builder.addIssue(.truncatedData, context: "RAF header")
            builder.focusPathMalformed = true
            return builder.makeReport()
        }
        do {
            // The authorized RAF sample stores the embedded JPEG offset and
            // length as big-endian 32-bit values at header bytes 84 and 88.
            // This is an observed entry point, not a claim about every RAF.
            let header = try reader.read(at: 0, count: 92)
            let jpegOffset = Int(readUInt32(header, at: 84, byteOrder: .bigEndian))
            let jpegLength = Int(readUInt32(header, at: 88, byteOrder: .bigEndian))
            guard jpegOffset >= 0, jpegOffset < reader.length else {
                builder.addIssue(.offsetOutOfBounds, context: "RAF embedded JPEG")
                builder.focusPathMalformed = true
                return builder.makeReport()
            }
            let jpegEnd: Int
            if jpegLength <= 0 {
                jpegEnd = reader.length
            } else {
                guard jpegLength <= reader.length - jpegOffset else {
                    builder.addIssue(.offsetOutOfBounds, context: "RAF embedded JPEG")
                    builder.focusPathMalformed = true
                    return builder.makeReport()
                }
                jpegEnd = jpegOffset + jpegLength
            }
            _ = extractEmbeddedJPEG(
                reader: reader,
                jpegStart: jpegOffset,
                jpegEnd: jpegEnd,
                kind: .fujifilmRAF,
                entryPoint: .embeddedJPEGExif(segmentOffset: 0),
                builder: builder
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "RAF header")
            builder.focusPathMalformed = true
        } catch {
            builder.focusPathMalformed = true
        }
        return builder.makeReport()
    }

    private func readJPEG(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .jpeg,
                byteOrder: nil,
                makerNoteFlavor: nil,
                entryPoint: .embeddedJPEGExif(segmentOffset: 0)
            )
        )
        _ = extractEmbeddedJPEG(
            reader: reader,
            jpegStart: 0,
            jpegEnd: reader.length,
            kind: .jpeg,
            entryPoint: .embeddedJPEGExif(segmentOffset: 0),
            builder: builder
        )
        return builder.makeReport()
    }

    private func readHEIF(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .heif,
                byteOrder: nil,
                makerNoteFlavor: nil,
                entryPoint: .heifMeta
            )
        )
        HEIFReader.extract(reader: reader, builder: builder, limits: limits)
        return builder.makeReport()
    }

    private func readCanonCR3(reader: BoundedReader) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: .canonCR3,
                byteOrder: nil,
                makerNoteFlavor: nil,
                entryPoint: .isoBMFFVendorBox(fourCC: "CMT3", tiffHeaderOffset: 0)
            )
        )
        CR3Reader.extract(reader: reader, builder: builder, limits: limits)
        return builder.makeReport()
    }

    @discardableResult
    private func extractEmbeddedJPEG(
        reader: BoundedReader,
        jpegStart: Int,
        jpegEnd: Int,
        kind: ContainerKind,
        entryPoint: MetadataEntryPoint,
        builder: ExtractionBuilder
    ) -> Bool {
        let segment: JPEGExifSegment
        do {
            guard
                let found = try JPEGScanner.findExifSegment(
                    reader: reader,
                    jpegStart: jpegStart,
                    jpegEnd: jpegEnd,
                    limits: limits
                )
            else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedVendorFocusLayout,
                    context: "JPEG APP1",
                    detail: "No Exif APP1 segment was found."
                )
                return false
            }
            segment = found
        } catch let failure as ParseFailure {
            builder.focusPathMalformed = true
            builder.addIssue(failure: failure, context: "JPEG APP1")
            return false
        } catch {
            builder.focusPathMalformed = true
            return false
        }

        do {
            let header = try TIFFHeaderParser.read(
                reader: reader,
                at: segment.tiffOffset,
                regionEnd: segment.tiffEnd
            )
            TIFFMetadataExtractor.extract(
                reader: reader,
                options: TIFFExtractionOptions(
                    containerKind: kind,
                    entryPoint: .embeddedJPEGExif(segmentOffset: segment.app1Offset),
                    base: segment.tiffOffset,
                    regionEnd: segment.tiffEnd,
                    byteOrder: header.byteOrder,
                    firstIFDOffset: header.firstIFDOffset
                ),
                builder: builder,
                limits: limits
            )
            return true
        } catch let failure as ParseFailure {
            builder.focusPathMalformed = true
            builder.addIssue(failure: failure, context: "Exif TIFF in JPEG")
            return false
        } catch {
            builder.focusPathMalformed = true
            return false
        }
    }

    private func readCameraASCII(
        _ index: TIFFEntryIndex,
        tag: UInt16,
        context: TIFFContext,
        builder: ExtractionBuilder
    ) -> String? {
        guard !index.duplicateTags.contains(tag) else {
            builder.addIssue(
                .duplicateTag,
                context: "IFD0 tag 0x\(String(tag, radix: 16))"
            )
            return nil
        }
        guard let entry = index.uniqueEntry(tag: tag), entry.type == 2 else {
            return nil
        }
        return try? context.readASCII(of: entry)
    }

    private func malformedReport(
        kind: ContainerKind,
        byteOrder: TIFFByteOrder? = nil,
        issue: MetadataIssue.Kind,
        context: String
    ) -> FocusMetadataReport {
        let builder = ExtractionBuilder(
            container: ContainerDescription(
                kind: kind,
                byteOrder: byteOrder,
                makerNoteFlavor: nil,
                entryPoint: .classicTIFFIFD0
            )
        )
        builder.addIssue(issue, context: context)
        builder.focusPathMalformed = true
        return builder.makeReport()
    }

    private func isTIFFSignature(_ head: [UInt8]) -> Bool {
        head.count >= 2
            && ((head[0] == 0x49 && head[1] == 0x49)
                || (head[0] == 0x4D && head[1] == 0x4D))
    }

    private func isRAFSIgnature(_ head: [UInt8]) -> Bool {
        guard head.count >= 16 else { return false }
        return Array(head[0..<16]) == Array("FUJIFILMCCD-RAW ".utf8)
    }

    private func ascii(_ bytes: [UInt8], range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            return nil
        }
        return String(bytes: bytes[range], encoding: .isoLatin1)
    }

    private func readUInt16(
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

    private func readUInt32(
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
