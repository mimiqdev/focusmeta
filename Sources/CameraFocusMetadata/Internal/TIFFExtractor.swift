import Foundation

struct TIFFExtractionOptions {
    var containerKind: ContainerKind
    var entryPoint: MetadataEntryPoint
    var base: Int
    var regionEnd: Int
    var byteOrder: TIFFByteOrder
    var firstIFDOffset: UInt32
    var parseMakerNote = true
    var parsePentaxVendorPayload = true
    var parseCanonVendorBlock = false
}

enum TIFFMetadataExtractor {
    static func extract(
        reader: BoundedReader,
        options: TIFFExtractionOptions,
        builder: ExtractionBuilder,
        limits: FocusMetadataReader.Limits
    ) {
        let context = TIFFContext(
            reader: reader,
            base: options.base,
            regionEnd: options.regionEnd,
            byteOrder: options.byteOrder
        )
        builder.container = ContainerDescription(
            kind: options.containerKind,
            byteOrder: options.byteOrder,
            makerNoteFlavor: nil,
            entryPoint: options.entryPoint
        )

        var visited: Set<Int> = []
        let ifd0: TIFFEntryIndex
        do {
            let absolute = try context.absolute(relativeOffset: options.firstIFDOffset)
            ifd0 = try TIFFDirectoryParser.parse(
                reader: reader,
                atAbsolute: absolute,
                context: context,
                limits: limits,
                visited: &visited,
                depth: 0
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "IFD0")
            builder.focusPathMalformed = true
            return
        } catch {
            builder.addIssue(.invalidIFD, context: "IFD0")
            builder.focusPathMalformed = true
            return
        }

        let make = readASCII(ifd0, tag: 0x010F, context: context, builder: builder)
        let model = readASCII(ifd0, tag: 0x0110, context: context, builder: builder)
        let software = readASCII(ifd0, tag: 0x0131, context: context, builder: builder)
        let vendor = cameraVendor(make: make, model: model)
        if make != nil || model != nil || software != nil {
            builder.camera = CameraIdentity(
                vendor: vendor,
                make: make,
                model: model,
                recordedSoftware: software
            )
        }

        readOrientation(ifd0, context: context, builder: builder)

        let exifIndex = readExifDirectory(
            ifd0,
            reader: reader,
            context: context,
            limits: limits,
            visited: &visited,
            builder: builder
        )

        if let exifIndex {
            readImageExtent(exifIndex, context: context, builder: builder)
        }

        if options.parseCanonVendorBlock {
            if let outcome = VendorReaders.readCanonCMT3(
                reader: reader,
                tiffOffset: options.base,
                tiffEnd: options.regionEnd,
                limits: limits
            ) {
                applyVendorResult(outcome, vendor: .canon, builder: builder)
            } else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedVendorFocusLayout,
                    context: "Canon CMT3 vendor block"
                )
            }
            return
        }

        if options.parsePentaxVendorPayload, let pentaxEntry = ifd0.uniqueEntry(tag: 0xC634) {
            if let payload = readPentaxPayload(
                entry: pentaxEntry,
                context: context,
                limits: limits,
                builder: builder
            ) {
                if let outcome = VendorReaders.readPentax(
                    reader: reader,
                    payloadOffset: payload.offset,
                    payloadLength: payload.length,
                    limits: limits
                ) {
                    builder.container = ContainerDescription(
                        kind: options.containerKind,
                        byteOrder: options.byteOrder,
                        makerNoteFlavor: .pentaxVendorPayload,
                        entryPoint: .tiffIFD0Tag(0xC634)
                    )
                    applyVendorResult(outcome, vendor: .pentax, builder: builder)
                    return
                }
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedVendorFocusLayout,
                    context: "Pentax vendor payload 0xc634"
                )
            }
        }

        guard options.parseMakerNote else { return }
        guard let exifIndex else {
            if vendor == .sony {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .missingExifIFD,
                    context: "Sony MakerNote entry point"
                )
            }
            return
        }

        readMakerNote(
            exifIndex,
            reader: reader,
            context: context,
            vendor: vendor,
            builder: builder,
            limits: limits
        )
    }

    private static func readASCII(
        _ index: TIFFEntryIndex,
        tag: UInt16,
        context: TIFFContext,
        builder: ExtractionBuilder
    ) -> String? {
        if index.duplicateTags.contains(tag) {
            builder.addIssue(
                .duplicateTag,
                context: "IFD0 tag 0x\(String(tag, radix: 16))"
            )
            return nil
        }
        guard let entry = index.uniqueEntry(tag: tag) else { return nil }
        guard entry.type == 2 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0x\(String(tag, radix: 16))"
            )
            return nil
        }
        do {
            return try context.readASCII(of: entry)
        } catch let failure as ParseFailure {
            builder.addIssue(
                failure: failure,
                context: "IFD0 tag 0x\(String(tag, radix: 16))"
            )
            return nil
        } catch {
            return nil
        }
    }

    private static func readOrientation(
        _ index: TIFFEntryIndex,
        context: TIFFContext,
        builder: ExtractionBuilder
    ) {
        if index.duplicateTags.contains(0x0112) {
            builder.addIssue(.duplicateTag, context: "IFD0 tag 0x0112")
            return
        }
        guard let entry = index.uniqueEntry(tag: 0x0112) else { return }
        guard entry.type == 3, entry.count == 1 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0x0112 orientation"
            )
            return
        }
        do {
            guard let raw = try context.singleUnsignedValue(of: entry),
                let value = UInt16(exactly: raw)
            else {
                builder.addIssue(
                    .unexpectedFieldShape,
                    context: "IFD0 tag 0x0112 orientation"
                )
                return
            }
            builder.exifOrientation = ExifOrientationRecord(rawValue: value)
        } catch let failure as ParseFailure {
            builder.addIssue(
                failure: failure,
                context: "IFD0 tag 0x0112 orientation"
            )
        } catch {}
    }

    private static func readExifDirectory(
        _ ifd0: TIFFEntryIndex,
        reader: BoundedReader,
        context: TIFFContext,
        limits: FocusMetadataReader.Limits,
        visited: inout Set<Int>,
        builder: ExtractionBuilder
    ) -> TIFFEntryIndex? {
        if ifd0.duplicateTags.contains(0x8769) {
            builder.addIssue(.duplicateTag, context: "IFD0 tag 0x8769")
            return nil
        }
        guard let pointer = ifd0.uniqueEntry(tag: 0x8769) else {
            return nil
        }
        guard pointer.type == 4, pointer.count == 1 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0x8769 Exif offset"
            )
            return nil
        }
        do {
            guard let raw = try context.singleUnsignedValue(of: pointer),
                raw <= UInt32.max
            else {
                builder.addIssue(
                    .unexpectedFieldShape,
                    context: "IFD0 tag 0x8769 Exif offset"
                )
                return nil
            }
            let absolute = try context.absolute(relativeOffset: UInt32(raw))
            return try TIFFDirectoryParser.parse(
                reader: reader,
                atAbsolute: absolute,
                context: context,
                limits: limits,
                visited: &visited,
                depth: 1
            )
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "Exif IFD")
            builder.focusPathMalformed = true
            return nil
        } catch {
            builder.focusPathMalformed = true
            return nil
        }
    }

    private static func readImageExtent(
        _ exifIndex: TIFFEntryIndex,
        context: TIFFContext,
        builder: ExtractionBuilder
    ) {
        let width = readDimension(
            exifIndex,
            tag: 0xA002,
            context: context,
            builder: builder
        )
        let height = readDimension(
            exifIndex,
            tag: 0xA003,
            context: context,
            builder: builder
        )
        if let width, let height {
            builder.imageExtent = PixelExtent(width: width, height: height)
        }
    }

    private static func readDimension(
        _ index: TIFFEntryIndex,
        tag: UInt16,
        context: TIFFContext,
        builder: ExtractionBuilder
    ) -> Int? {
        if index.duplicateTags.contains(tag) {
            builder.addIssue(.duplicateTag, context: "Exif tag 0x\(String(tag, radix: 16))")
            return nil
        }
        guard let entry = index.uniqueEntry(tag: tag) else { return nil }
        guard entry.type == 3 || entry.type == 4, entry.count == 1 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "Exif tag 0x\(String(tag, radix: 16))"
            )
            return nil
        }
        do {
            guard let raw = try context.singleUnsignedValue(of: entry) else {
                builder.addIssue(
                    .unexpectedFieldShape,
                    context: "Exif tag 0x\(String(tag, radix: 16))"
                )
                return nil
            }
            guard raw > 0 else {
                builder.addIssue(
                    .zeroImageExtent,
                    context: "Exif tag 0x\(String(tag, radix: 16))"
                )
                return nil
            }
            guard raw <= UInt64(Int.max) else {
                builder.addIssue(
                    .arithmeticOverflow,
                    context: "Exif tag 0x\(String(tag, radix: 16))"
                )
                return nil
            }
            return Int(raw)
        } catch let failure as ParseFailure {
            builder.addIssue(
                failure: failure,
                context: "Exif tag 0x\(String(tag, radix: 16))"
            )
            return nil
        } catch {
            return nil
        }
    }

    private static func readPentaxPayload(
        entry: TIFFEntry,
        context: TIFFContext,
        limits: FocusMetadataReader.Limits,
        builder: ExtractionBuilder
    ) -> (offset: Int, length: Int)? {
        guard entry.type == 1 || entry.type == 7 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0xc634 Pentax payload"
            )
            return nil
        }
        guard let byteCount = entry.declaredByteCount, byteCount > 0 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0xc634 Pentax payload"
            )
            return nil
        }
        guard byteCount <= limits.maximumMakerNoteBytes else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "IFD0 tag 0xc634 Pentax payload",
                detail: "The declared payload exceeds the MakerNote size limit."
            )
            return nil
        }
        do {
            let offset = try context.valueOffset(for: entry)
            guard byteCount <= context.regionEnd - offset else {
                builder.addIssue(
                    .offsetOutOfBounds,
                    context: "IFD0 tag 0xc634 Pentax payload"
                )
                return nil
            }
            let prefixLength = min(10, byteCount)
            let prefix = try context.read(atAbsolute: offset, count: prefixLength)
            guard prefix.starts(with: Array("PENTAX".utf8)) else {
                // 0xc634 is also present in small, unrelated vendor fields.
                return nil
            }
            return (offset, byteCount)
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "IFD0 tag 0xc634 Pentax payload")
            return nil
        } catch {
            return nil
        }
    }

    private static func readMakerNote(
        _ exifIndex: TIFFEntryIndex,
        reader: BoundedReader,
        context: TIFFContext,
        vendor: CameraVendor,
        builder: ExtractionBuilder,
        limits: FocusMetadataReader.Limits
    ) {
        if exifIndex.duplicateTags.contains(0x927C) {
            builder.addIssue(.duplicateTag, context: "Exif tag 0x927c MakerNote")
            builder.focusPathMalformed = true
            return
        }
        guard let entry = exifIndex.uniqueEntry(tag: 0x927C) else {
            if vendor == .sony {
                builder.focusPathUnsupported = true
                builder.addIssue(.missingMakerNote, context: "Sony MakerNote")
            } else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedVendorFocusLayout,
                    context: "MakerNote"
                )
            }
            return
        }
        guard entry.type == 7 else {
            builder.focusPathMalformed = true
            builder.addIssue(
                .unexpectedFieldShape,
                context: "Exif tag 0x927c MakerNote"
            )
            return
        }
        guard let byteCount = entry.declaredByteCount, byteCount > 0 else {
            builder.focusPathMalformed = true
            builder.addIssue(
                .unexpectedFieldShape,
                context: "Exif tag 0x927c MakerNote"
            )
            return
        }
        guard byteCount <= limits.maximumMakerNoteBytes else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unexpectedFieldShape,
                context: "Exif tag 0x927c MakerNote",
                detail: "The declared MakerNote exceeds the configured size limit."
            )
            return
        }

        let makerNoteOffset: Int
        do {
            makerNoteOffset = try context.valueOffset(for: entry)
        } catch let failure as ParseFailure {
            builder.focusPathMalformed = true
            builder.addIssue(failure: failure, context: "Exif tag 0x927c MakerNote")
            return
        } catch {
            builder.focusPathMalformed = true
            return
        }

        guard byteCount <= context.regionEnd - makerNoteOffset else {
            builder.focusPathMalformed = true
            builder.addIssue(
                .offsetOutOfBounds,
                context: "Exif tag 0x927c MakerNote",
                detail: "The declared MakerNote extent exceeds the enclosing TIFF region."
            )
            return
        }

        let prefixLength = min(16, byteCount)
        let prefix: [UInt8]
        do {
            prefix = try context.read(atAbsolute: makerNoteOffset, count: prefixLength)
        } catch let failure as ParseFailure {
            builder.focusPathMalformed = true
            builder.addIssue(failure: failure, context: "Exif tag 0x927c MakerNote")
            return
        } catch {
            builder.focusPathMalformed = true
            return
        }

        if isSonyPrefixed(prefix) {
            applySony(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                byteCount: byteCount,
                prefixed: true,
                context: context,
                imageExtent: builder.imageExtent,
                builder: builder,
                limits: limits
            )
            return
        }
        if prefix.starts(with: Array("Nikon".utf8)) {
            if let outcome = VendorReaders.readNikon(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                makerNoteLength: byteCount,
                limits: limits
            ) {
                setMakerNoteFlavor(.nikonEmbeddedTIFF, builder: builder)
                applyVendorResult(outcome, vendor: .nikon, builder: builder)
            } else {
                unsupportedMakerNote(builder: builder, name: "Nikon")
            }
            return
        }
        if prefix.starts(with: Array("FUJIFILM".utf8)) {
            if let outcome = VendorReaders.readFujifilm(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                makerNoteLength: byteCount,
                outerByteOrder: context.byteOrder,
                limits: limits
            ) {
                setMakerNoteFlavor(.fujifilm, builder: builder)
                applyVendorResult(outcome, vendor: .fujifilm, builder: builder)
            } else {
                unsupportedMakerNote(builder: builder, name: "Fujifilm")
            }
            return
        }
        if prefix.starts(with: Array("Panasonic".utf8)) {
            if let outcome = VendorReaders.readPanasonic(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                makerNoteLength: byteCount,
                outerContext: context,
                limits: limits
            ) {
                setMakerNoteFlavor(.panasonic, builder: builder)
                applyVendorResult(outcome, vendor: .panasonic, builder: builder)
            } else {
                unsupportedMakerNote(builder: builder, name: "Panasonic")
            }
            return
        }
        if prefix.starts(with: Array("OLYMPUS".utf8)) {
            if let outcome = VendorReaders.readOlympus(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                makerNoteLength: byteCount,
                limits: limits
            ) {
                setMakerNoteFlavor(.olympus, builder: builder)
                applyVendorResult(outcome, vendor: .olympus, builder: builder)
            } else {
                unsupportedMakerNote(builder: builder, name: "Olympus")
            }
            return
        }

        if vendor == .sony
            || looksLikeSonyUnprefixed(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                byteCount: byteCount,
                context: context,
                limits: limits
            )
        {
            applySony(
                reader: reader,
                makerNoteOffset: makerNoteOffset,
                byteCount: byteCount,
                prefixed: false,
                context: context,
                imageExtent: builder.imageExtent,
                builder: builder,
                limits: limits
            )
            return
        }

        unsupportedMakerNote(builder: builder, name: "unknown")
    }

    private static func applySony(
        reader: BoundedReader,
        makerNoteOffset: Int,
        byteCount: Int,
        prefixed: Bool,
        context: TIFFContext,
        imageExtent: PixelExtent?,
        builder: ExtractionBuilder,
        limits: FocusMetadataReader.Limits
    ) {
        let outcome = SonyReader.read(
            reader: reader,
            makerNoteOffset: makerNoteOffset,
            makerNoteLength: byteCount,
            prefixed: prefixed,
            context: context,
            limits: limits,
            imageExtent: imageExtent
        )
        builder.focusPathSupported = true
        builder.addIssues(outcome.issues)
        builder.addUncertainties(outcome.uncertainties)
        let flavor: MakerNoteFlavor = prefixed ? .sonyPrefixed : .sonyUnprefixed
        setMakerNoteFlavor(flavor, builder: builder)
        if outcome.malformedFocusPath {
            builder.focusPathMalformed = true
        }
        if let focus = outcome.focus {
            builder.focus = focus
        } else {
            builder.addIssue(
                .missingFocusMetadata,
                context: "Sony MakerNote",
                detail: "The observed Sony focus tags were absent."
            )
        }
    }

    private static func applyVendorResult(
        _ outcome: VendorReadOutcome,
        vendor: CameraVendor,
        builder: ExtractionBuilder
    ) {
        builder.focusPathSupported = true
        builder.addIssues(outcome.issues)
        if outcome.malformedFocusPath {
            builder.focusPathMalformed = true
        }
        guard !outcome.records.isEmpty else { return }
        builder.focus = RecordedFocus(
            source: outcome.source,
            referenceExtent: outcome.referenceExtent,
            geometry: .unavailable(outcome.unavailability),
            frame: nil,
            sony: nil,
            vendor: VendorFocusFields(vendor: vendor, records: outcome.records)
        )
        builder.addUncertainty(.vendorGeometryUnverified)
    }

    private static func setMakerNoteFlavor(
        _ flavor: MakerNoteFlavor,
        builder: ExtractionBuilder
    ) {
        builder.container = ContainerDescription(
            kind: builder.container.kind,
            byteOrder: builder.container.byteOrder,
            makerNoteFlavor: flavor,
            entryPoint: builder.container.entryPoint
        )
    }

    private static func unsupportedMakerNote(
        builder: ExtractionBuilder,
        name: String
    ) {
        builder.focusPathUnsupported = true
        builder.addIssue(
            .unsupportedMakerNoteLayout,
            context: "MakerNote",
            detail: "The \(name) MakerNote layout is outside the supported entry points."
        )
    }

    private static func isSonyPrefixed(_ prefix: [UInt8]) -> Bool {
        guard prefix.count >= 12 else { return false }
        return prefix.starts(with: Array("SONY DSC ".utf8))
            && prefix[9] == 0 && prefix[10] == 0 && prefix[11] == 0
    }

    private static func looksLikeSonyUnprefixed(
        reader: BoundedReader,
        makerNoteOffset: Int,
        byteCount: Int,
        context: TIFFContext,
        limits: FocusMetadataReader.Limits
    ) -> Bool {
        guard byteCount >= 2 else { return false }
        var visited: Set<Int> = []
        guard
            let index = try? TIFFDirectoryParser.parse(
                reader: reader,
                atAbsolute: makerNoteOffset,
                context: context,
                limits: limits,
                visited: &visited,
                depth: 1
            )
        else {
            return false
        }
        let sonyTags: Set<UInt16> = [0x201B, 0x201C, 0x2020, 0x2027, 0x2037, 0x204A]
        return index.entries.contains { sonyTags.contains($0.tag) }
    }

    static func cameraVendor(make: String?, model: String?) -> CameraVendor {
        let makeValue = make?.uppercased() ?? ""
        let modelValue = model?.uppercased() ?? ""
        if makeValue.contains("SONY") { return .sony }
        if makeValue.contains("CANON") { return .canon }
        if makeValue.contains("NIKON") { return .nikon }
        if makeValue.contains("FUJI") { return .fujifilm }
        if makeValue.contains("PANASONIC") { return .panasonic }
        if makeValue.contains("OLYMPUS") || makeValue.contains("OM DIGITAL") { return .olympus }
        if makeValue.contains("PENTAX") || makeValue.contains("RICOH") { return .pentax }

        if modelValue.contains("ILCE") || modelValue.hasPrefix("NEX-")
            || modelValue.hasPrefix("DSC-") || modelValue.hasPrefix("ZV-")
        {
            return .sony
        }
        if modelValue.contains("NIKON") { return .nikon }
        if modelValue.contains("FUJIFILM") { return .fujifilm }
        if modelValue.contains("PANASONIC") { return .panasonic }
        if modelValue.contains("OLYMPUS") { return .olympus }
        if modelValue.contains("PENTAX") { return .pentax }
        return .unknown
    }
}
