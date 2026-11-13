import Foundation

enum HEIFReader {
    static func extract(
        reader: BoundedReader,
        builder: ExtractionBuilder,
        limits: FocusMetadataReader.Limits
    ) {
        let metaBox: BMFFBox
        do {
            guard let found = try findMetaBox(reader: reader, limits: limits) else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedHEIFLayout,
                    context: "ISO BMFF",
                    detail: "No top-level meta box was present."
                )
                return
            }
            metaBox = found
        } catch let failure as ParseFailure {
            builder.focusPathUnsupported = true
            builder.addIssue(failure: failure, context: "ISO BMFF")
            return
        } catch {
            builder.focusPathUnsupported = true
            return
        }

        let metadata: HEIFMetadata
        do {
            metadata = try HEIFParser.parse(reader: reader, meta: metaBox, limits: limits)
        } catch let failure as ParseFailure {
            builder.focusPathUnsupported = true
            builder.addIssue(failure: failure, context: "HEIF meta box")
            return
        } catch {
            builder.focusPathUnsupported = true
            return
        }

        guard let primaryItemID = metadata.primaryItemID else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF pitm",
                detail: "No primary item was declared."
            )
            return
        }

        let primaryExtent = primaryImageExtent(
            metadata: metadata,
            primaryItemID: primaryItemID,
            reader: reader,
            builder: builder
        )
        let primaryRotation = primaryImageRotation(
            metadata: metadata,
            primaryItemID: primaryItemID,
            reader: reader,
            builder: builder
        )

        let exifItems = metadata.items.values.filter { $0.itemType == "Exif" }
        guard
            let exifItem = selectExifItem(
                exifItems,
                metadata: metadata,
                primaryItemID: primaryItemID,
                builder: builder
            )
        else {
            builder.focusPathUnsupported = true
            if exifItems.isEmpty {
                builder.addIssue(
                    .unsupportedHEIFLayout,
                    context: "HEIF Exif item",
                    detail: "No item of type Exif was present."
                )
            }
            return
        }

        guard let location = metadata.locations[exifItem.itemID] else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF iloc",
                detail: "The Exif item had no location record."
            )
            return
        }
        guard location.constructionMethod == 0 else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF iloc",
                detail: "Only construction method 0 was verified for the Exif item."
            )
            return
        }
        guard location.dataReferenceIndex == 0 else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF iloc",
                detail: "External data references were not verified for the Exif item."
            )
            return
        }
        guard location.baseOffset == 0 else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF iloc",
                detail: "A nonzero base offset was not verified for the Exif item."
            )
            return
        }
        guard location.extents.count == 1, let extent = location.extents.first else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF iloc",
                detail: "Only a single-extent Exif item was verified."
            )
            return
        }
        guard extent.length > 0, extent.length <= UInt64(limits.maximumValueBytes),
            extent.offset <= UInt64(reader.length),
            extent.length <= UInt64(reader.length) - extent.offset
        else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .offsetOutOfBounds,
                context: "HEIF Exif item extent"
            )
            return
        }

        let itemOffset = Int(extent.offset)
        let itemLength = Int(extent.length)
        let itemEnd = itemOffset + itemLength
        guard itemLength >= 10 else {
            builder.focusPathUnsupported = true
            builder.addIssue(
                .truncatedData,
                context: "HEIF Exif item"
            )
            return
        }

        do {
            let displacementBytes = try reader.read(at: itemOffset, count: 4)
            let displacement = BMFFParser.decodeUInt32(
                displacementBytes,
                at: 0,
                byteOrder: .bigEndian
            )
            let identifier = try reader.read(at: itemOffset + 4, count: 6)
            guard identifier == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedHEIFLayout,
                    context: "HEIF Exif item",
                    detail: "The Exif identifier was absent."
                )
                return
            }
            let tiffHeaderOffset = 4 + Int(displacement)
            guard tiffHeaderOffset >= 10, tiffHeaderOffset <= itemLength,
                itemLength - tiffHeaderOffset >= 8
            else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .offsetOutOfBounds,
                    context: "HEIF Exif displacement"
                )
                return
            }
            let tiffOffset = itemOffset + tiffHeaderOffset
            let header = try TIFFHeaderParser.read(
                reader: reader,
                at: tiffOffset,
                regionEnd: itemEnd
            )
            TIFFMetadataExtractor.extract(
                reader: reader,
                options: TIFFExtractionOptions(
                    containerKind: .heif,
                    entryPoint: .heifExifItem(
                        itemID: exifItem.itemID,
                        extentLength: itemLength,
                        tiffHeaderOffset: tiffHeaderOffset
                    ),
                    base: tiffOffset,
                    regionEnd: itemEnd,
                    byteOrder: header.byteOrder,
                    firstIFDOffset: header.firstIFDOffset,
                    parseMakerNote: true,
                    parsePentaxVendorPayload: false,
                    parseCanonVendorBlock: false
                ),
                builder: builder,
                limits: limits
            )
        } catch let failure as ParseFailure {
            builder.focusPathUnsupported = true
            builder.addIssue(failure: failure, context: "HEIF Exif item")
            return
        } catch {
            builder.focusPathUnsupported = true
            return
        }

        if let primaryExtent {
            if let exifExtent = builder.imageExtent, exifExtent != primaryExtent {
                builder.addIssue(
                    .unverifiedGeometry,
                    context: "HEIF ispe and Exif dimensions",
                    detail:
                        "The primary-image extent and Exif dimensions differ; ispe is reported."
                )
                builder.addUncertainty(.referenceExtentMismatch)
            }
            builder.imageExtent = primaryExtent
        }
        if let primaryRotation {
            builder.primaryImageRotation = primaryRotation
        }
    }

    private static func findMetaBox(
        reader: BoundedReader,
        limits: FocusMetadataReader.Limits
    ) throws -> BMFFBox? {
        var counter = 0
        var found: BMFFBox?
        try BMFFParser.forEachBox(
            reader: reader,
            start: 0,
            end: reader.length,
            depth: 0,
            limits: limits,
            boxCounter: &counter
        ) { box in
            if box.type == "meta", found == nil {
                found = box
            }
        }
        return found
    }

    private static func selectExifItem(
        _ exifItems: [HEIFItemInfo],
        metadata: HEIFMetadata,
        primaryItemID: UInt32,
        builder: ExtractionBuilder
    ) -> HEIFItemInfo? {
        guard !exifItems.isEmpty else { return nil }

        let cdscReferences = metadata.references.filter { $0.type == "cdsc" }
        func targets(for item: HEIFItemInfo) -> [UInt32]? {
            let references = cdscReferences.filter { $0.fromItemID == item.itemID }
            guard !references.isEmpty else { return nil }
            return references.flatMap(\.toItemIDs)
        }

        if exifItems.count == 1 {
            let item = exifItems[0]
            guard let targets = targets(for: item) else {
                builder.addIssue(
                    .unsupportedHEIFLayout,
                    context: "HEIF Exif item cdsc",
                    detail: "The Exif item had no explicit cdsc association."
                )
                return nil
            }
            guard targets == [primaryItemID] else {
                builder.addIssue(
                    .unsupportedHEIFLayout,
                    context: "HEIF Exif item cdsc",
                    detail:
                        "The Exif item is not linked exclusively to the declared primary item."
                )
                return nil
            }
            return item
        }

        let primaryLinked = exifItems.filter { targets(for: $0) == [primaryItemID] }
        guard primaryLinked.count == 1 else {
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF Exif item selection",
                detail:
                    "Multiple Exif items were present without one exclusive primary-item association."
            )
            return nil
        }
        builder.addIssue(
            .unverifiedGeometry,
            context: "HEIF Exif item selection",
            detail:
                "Multiple Exif items existed; the only item explicitly linked to the primary item was used."
        )
        return primaryLinked[0]
    }

    private static func primaryImageExtent(
        metadata: HEIFMetadata,
        primaryItemID: UInt32,
        reader: BoundedReader,
        builder: ExtractionBuilder
    ) -> PixelExtent? {
        let properties = associatedProperties(
            itemID: primaryItemID,
            metadata: metadata
        )
        let ispe = properties.filter { $0.type == "ispe" }
        if ispe.count > 1 {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "HEIF primary ispe",
                detail: "More than one ispe property was associated with the primary item."
            )
        }
        guard let property = ispe.first else { return nil }
        guard property.payloadEnd - property.payloadStart >= 12 else {
            builder.addIssue(
                .unexpectedFieldShape,
                context: "HEIF primary ispe"
            )
            return nil
        }
        do {
            let width = try reader.u32(
                at: property.payloadStart + 4,
                byteOrder: .bigEndian
            )
            let height = try reader.u32(
                at: property.payloadStart + 8,
                byteOrder: .bigEndian
            )
            guard width > 0, height > 0 else {
                builder.addIssue(
                    .zeroImageExtent,
                    context: "HEIF primary ispe"
                )
                return nil
            }
            return PixelExtent(width: Int(width), height: Int(height))
        } catch let failure as ParseFailure {
            builder.addIssue(failure: failure, context: "HEIF primary ispe")
            return nil
        } catch {
            return nil
        }
    }

    private static func primaryImageRotation(
        metadata: HEIFMetadata,
        primaryItemID: UInt32,
        reader: BoundedReader,
        builder: ExtractionBuilder
    ) -> PrimaryImageRotation? {
        if let associations = metadata.associations[primaryItemID] {
            let hasInvalidIndex = associations.contains {
                $0.propertyIndex < 1 || $0.propertyIndex > metadata.properties.count
            }
            if hasInvalidIndex {
                builder.primaryImageTransformUnsupported = true
                builder.addIssue(
                    .unexpectedFieldShape,
                    context: "HEIF primary ipma",
                    detail: "A transform association referenced an unknown property index."
                )
            }
        }

        let properties = associatedProperties(
            itemID: primaryItemID,
            metadata: metadata
        )
        let unsupported = properties.filter { $0.type == "imir" || $0.type == "clap" }
        if !unsupported.isEmpty {
            builder.primaryImageTransformUnsupported = true
            builder.addIssue(
                .unsupportedHEIFLayout,
                context: "HEIF primary image transforms",
                detail: "imir or clap was present; mirroring and crop precedence were not verified."
            )
            return nil
        }
        let rotations = properties.filter { $0.type == "irot" }
        if rotations.count > 1 {
            builder.primaryImageTransformUnsupported = true
            builder.addIssue(
                .unexpectedFieldShape,
                context: "HEIF primary irot",
                detail: "More than one irot property was associated with the primary item."
            )
            return nil
        }
        guard let property = rotations.first else { return nil }
        guard property.payloadEnd > property.payloadStart else {
            builder.primaryImageTransformUnsupported = true
            builder.addIssue(
                .truncatedData,
                context: "HEIF primary irot"
            )
            return nil
        }
        do {
            let payload = try reader.u8(at: property.payloadStart)
            return PrimaryImageRotation(rawPayload: payload)
        } catch let failure as ParseFailure {
            builder.primaryImageTransformUnsupported = true
            builder.addIssue(failure: failure, context: "HEIF primary irot")
            return nil
        } catch {
            builder.primaryImageTransformUnsupported = true
            return nil
        }
    }

    private static func associatedProperties(
        itemID: UInt32,
        metadata: HEIFMetadata
    ) -> [HEIFProperty] {
        guard let associations = metadata.associations[itemID] else { return [] }
        return associations.compactMap { association in
            guard association.propertyIndex >= 1,
                association.propertyIndex <= metadata.properties.count
            else {
                return nil
            }
            return metadata.properties[association.propertyIndex - 1]
        }
    }
}
