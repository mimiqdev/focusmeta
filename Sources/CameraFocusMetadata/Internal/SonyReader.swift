import Foundation

struct SonyReadOutcome {
    var focus: RecordedFocus?
    var sawFocusFields = false
    var malformedFocusPath = false
    var issues: [MetadataIssue] = []
    var uncertainties: [Uncertainty] = []
}

enum SonyReader {
    private static let locationTag: UInt16 = 0x2027
    private static let secondaryLocationTag: UInt16 = 0x204A
    private static let frameTag: UInt16 = 0x2037
    private static let modeTag: UInt16 = 0x201B
    private static let areaTag: UInt16 = 0x201C
    private static let legacyPointsTag: UInt16 = 0x2020

    static func read(
        reader: BoundedReader,
        makerNoteOffset: Int,
        makerNoteLength: Int,
        prefixed: Bool,
        context: TIFFContext,
        limits: FocusMetadataReader.Limits,
        imageExtent: PixelExtent?
    ) -> SonyReadOutcome {
        var outcome = SonyReadOutcome()
        let prefixLength = prefixed ? 12 : 0
        let directoryOffset = makerNoteOffset + prefixLength
        let makerNoteEnd = makerNoteOffset + makerNoteLength
        guard directoryOffset >= 0, directoryOffset + 2 <= makerNoteEnd else {
            outcome.issues.append(
                MetadataIssue(
                    kind: .malformedMakerNote,
                    context: "Sony MakerNote directory",
                    detail: "The MakerNote is too short to contain a directory count."
                )
            )
            outcome.malformedFocusPath = true
            return outcome
        }

        var visited: Set<Int> = []
        let index: TIFFEntryIndex
        do {
            index = try TIFFDirectoryParser.parse(
                reader: reader,
                atAbsolute: directoryOffset,
                context: context,
                limits: limits,
                visited: &visited,
                depth: 1,
                tableEnd: makerNoteEnd
            )
        } catch let failure as ParseFailure {
            outcome.issues.append(
                MetadataIssue(failure: failure, context: "Sony MakerNote directory")
            )
            outcome.malformedFocusPath = true
            return outcome
        } catch {
            outcome.issues.append(
                MetadataIssue(kind: .malformedMakerNote, context: "Sony MakerNote directory")
            )
            outcome.malformedFocusPath = true
            return outcome
        }

        for tag in [modeTag, areaTag, legacyPointsTag, locationTag, frameTag, secondaryLocationTag]
        where index.duplicateTags.contains(tag) {
            outcome.issues.append(
                MetadataIssue(
                    kind: .duplicateTag,
                    context: "Sony MakerNote tag 0x\(String(tag, radix: 16))"
                )
            )
            if tag == locationTag || tag == frameTag || tag == secondaryLocationTag {
                outcome.malformedFocusPath = true
            }
        }

        var locationWords: [UInt16]?
        var secondaryLocationWords: [UInt16]?
        var frameRawBytes: [UInt8]?
        var frame: RecordedFrame?
        var mode: RecordedMode?
        var areaCode: UInt8?
        var legacyBytes: [UInt8]?

        if let entry = index.uniqueEntry(tag: locationTag) {
            outcome.sawFocusFields = true
            do {
                locationWords = try readLocationWords(
                    entry: entry,
                    context: context,
                    label: "Sony 0x2027",
                    outcome: &outcome
                )
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x2027 location")
                )
                outcome.malformedFocusPath = true
            } catch {
                outcome.malformedFocusPath = true
            }
        }

        if let entry = index.uniqueEntry(tag: secondaryLocationTag) {
            outcome.sawFocusFields = true
            do {
                secondaryLocationWords = try readLocationWords(
                    entry: entry,
                    context: context,
                    label: "Sony 0x204a",
                    outcome: &outcome
                )
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x204a location")
                )
                outcome.malformedFocusPath = true
            } catch {
                outcome.malformedFocusPath = true
            }
        }

        if let entry = index.uniqueEntry(tag: frameTag) {
            outcome.sawFocusFields = true
            do {
                let bytes = try readFrameBytes(entry: entry, context: context, outcome: &outcome)
                frameRawBytes = bytes
                if let bytes, bytes.count == 6 {
                    if context.byteOrder == .littleEndian {
                        let width = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
                        let height = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
                        let availability = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
                        frame = RecordedFrame(
                            width: width,
                            height: height,
                            availabilityWord: availability
                        )
                    } else {
                        outcome.uncertainties.append(.bigEndianFrameEncodingUnverified)
                        outcome.issues.append(
                            MetadataIssue(
                                kind: .unsupportedSonyFrameByteOrder,
                                context: "Sony 0x2037 frame",
                                detail:
                                    "Only little-endian frame records were verified; raw bytes are retained unchanged."
                            )
                        )
                    }
                }
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x2037 frame")
                )
                outcome.malformedFocusPath = true
            } catch {
                outcome.malformedFocusPath = true
            }
        }

        if let entry = index.uniqueEntry(tag: modeTag) {
            do {
                if entry.type == 1, entry.count == 1 {
                    if let byte = try context.singleByte(of: entry) {
                        mode = RecordedMode(
                            code: byte,
                            referenceToolLabel: byte == 3 ? "AF-C" : nil
                        )
                        if mode?.referenceToolLabel != nil {
                            outcome.uncertainties.append(.recordedModeLabelFromReferenceToolOnly)
                        }
                    }
                } else {
                    addShapeIssue(tag: modeTag, outcome: &outcome)
                }
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x201b mode")
                )
            } catch {
                // The shape issue above already describes the field.
            }
        }

        if let entry = index.uniqueEntry(tag: areaTag) {
            do {
                if entry.type == 1, entry.count == 1 {
                    areaCode = try context.singleByte(of: entry)
                } else {
                    addShapeIssue(tag: areaTag, outcome: &outcome)
                }
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x201c area mode")
                )
            } catch {
                // The shape issue above already describes the field.
            }
        }

        if let entry = index.uniqueEntry(tag: legacyPointsTag) {
            do {
                if entry.type == 1, entry.count > 0, entry.count <= 64 {
                    legacyBytes = try context.readValue(of: entry)
                    if entry.count != 10 {
                        addShapeIssue(tag: legacyPointsTag, outcome: &outcome)
                    }
                } else {
                    addShapeIssue(tag: legacyPointsTag, outcome: &outcome)
                }
            } catch let failure as ParseFailure {
                outcome.issues.append(
                    MetadataIssue(failure: failure, context: "Sony 0x2020 legacy points")
                )
            } catch {
                // The shape issue above already describes the field.
            }
        }

        guard outcome.sawFocusFields else {
            return outcome
        }

        let referenceExtent: PixelExtent?
        if let locationWords, locationWords.count == 4 {
            referenceExtent = PixelExtent(
                width: Int(locationWords[0]),
                height: Int(locationWords[1])
            )
        } else {
            referenceExtent = nil
        }

        if let locationWords, let secondaryLocationWords,
            locationWords != secondaryLocationWords
        {
            outcome.issues.append(
                MetadataIssue(
                    kind: .conflictingFocusLocations,
                    context: "Sony 0x2027 and 0x204a",
                    detail: "The values differ; their precedence is not established."
                )
            )
        }
        if secondaryLocationWords != nil {
            outcome.uncertainties.append(.secondLocationRelationUnverified)
        }

        if let referenceExtent, let imageExtent, referenceExtent != imageExtent {
            outcome.issues.append(
                MetadataIssue(
                    kind: .referenceExtentMismatch,
                    context: "Sony 0x2027 reference extent",
                    detail:
                        "The focus record's reference extent differs from the image extent."
                )
            )
            outcome.uncertainties.append(.referenceExtentMismatch)
        }

        let geometry = resolveGeometry(
            locationWords: locationWords,
            referenceExtent: referenceExtent,
            frame: frame,
            frameRawBytes: frameRawBytes,
            byteOrder: context.byteOrder,
            outcome: &outcome
        )

        outcome.uncertainties.append(contentsOf: [
            .playbackZoomHintIsNotConfirmedFocus,
            .focusSuccessNotEstablished,
            .coordinateIndexConventionUnverified,
        ])
        if frame != nil {
            outcome.uncertainties.append(.availabilityWordBitsUnverified)
        }
        if let locationWords, locationWords.count == 4,
            locationWords[0] > 0, locationWords[1] > 0,
            Int(locationWords[2]) * 2 == Int(locationWords[0]),
            Int(locationWords[3]) * 2 == Int(locationWords[1])
        {
            outcome.uncertainties.append(.centerMayBeCameraFallback)
        }
        if case .region = geometry {
            outcome.uncertainties.append(.continuousCoordinateApproximation)
        }
        if case .location = geometry {
            outcome.uncertainties.append(.continuousCoordinateApproximation)
        }

        let fields = SonyFocusFields(
            locationWords: locationWords,
            secondaryLocationWords: secondaryLocationWords,
            frameRawBytes: frameRawBytes,
            mode: mode,
            configuredAreaModeCode: areaCode,
            legacyPointUseBytes: legacyBytes,
            locationsDiffer: {
                guard let locationWords, let secondaryLocationWords else { return nil }
                return locationWords != secondaryLocationWords
            }()
        )

        outcome.focus = RecordedFocus(
            source: locationWords == nil ? .sonyFocusFields : .sonyLocationRecord,
            referenceExtent: referenceExtent,
            geometry: geometry,
            frame: frame,
            sony: fields,
            vendor: nil
        )
        return outcome
    }

    private static func readLocationWords(
        entry: TIFFEntry,
        context: TIFFContext,
        label: String,
        outcome: inout SonyReadOutcome
    ) throws -> [UInt16]? {
        guard entry.type == 3, entry.count == 4 else {
            outcome.issues.append(
                MetadataIssue(
                    kind: .unexpectedFieldShape,
                    context: label,
                    detail:
                        "Expected TIFF SHORT count 4; found type \(entry.type) count \(entry.count)."
                )
            )
            outcome.malformedFocusPath = true
            return nil
        }
        guard let values = try context.readUnsignedValues(of: entry) else {
            outcome.issues.append(
                MetadataIssue(
                    kind: .unsupportedValueLayout,
                    context: label
                )
            )
            outcome.malformedFocusPath = true
            return nil
        }
        var words: [UInt16] = []
        words.reserveCapacity(values.count)
        for value in values {
            guard let word = UInt16(exactly: value) else {
                outcome.issues.append(
                    MetadataIssue(
                        kind: .unexpectedFieldShape,
                        context: label,
                        detail: "A SHORT value exceeded the 16-bit range."
                    )
                )
                outcome.malformedFocusPath = true
                return nil
            }
            words.append(word)
        }
        return words
    }

    private static func readFrameBytes(
        entry: TIFFEntry,
        context: TIFFContext,
        outcome: inout SonyReadOutcome
    ) throws -> [UInt8]? {
        guard entry.type == 7, entry.count == 6 else {
            outcome.issues.append(
                MetadataIssue(
                    kind: .unexpectedFieldShape,
                    context: "Sony 0x2037 frame",
                    detail:
                        "Expected TIFF UNDEFINED count 6; found type \(entry.type) count \(entry.count)."
                )
            )
            outcome.malformedFocusPath = true
            return nil
        }
        return try context.readValue(of: entry)
    }

    private static func addShapeIssue(
        tag: UInt16,
        outcome: inout SonyReadOutcome
    ) {
        outcome.issues.append(
            MetadataIssue(
                kind: .unexpectedFieldShape,
                context: "Sony tag 0x\(String(tag, radix: 16))"
            )
        )
    }

    private static func resolveGeometry(
        locationWords: [UInt16]?,
        referenceExtent: PixelExtent?,
        frame: RecordedFrame?,
        frameRawBytes: [UInt8]?,
        byteOrder: TIFFByteOrder,
        outcome: inout SonyReadOutcome
    ) -> FocusGeometry {
        guard let locationWords, locationWords.count == 4 else {
            return .unavailable(.noLocationRecorded)
        }
        guard let referenceExtent else {
            return .unavailable(.zeroReferenceExtent)
        }

        let x = Double(locationWords[2])
        let y = Double(locationWords[3])
        let center = ContinuousPoint(x: x, y: y)
        if x > Double(referenceExtent.width) || y > Double(referenceExtent.height) {
            return .unavailable(.centerOutsideReference)
        }

        if let frame {
            switch frame.referenceToolPresentation {
            case .notDisplayed:
                return .unavailable(.frameNotPresentedByReferenceTools)
            case .unobserved:
                return .unavailable(
                    .frameAvailabilityWordUnverified(frame.availabilityWord)
                )
            case .displayed:
                if frame.width == 0 || frame.height == 0 {
                    return .unavailable(.zeroRegionExtent)
                }
                let size = ContinuousSize(
                    width: Double(frame.width),
                    height: Double(frame.height)
                )
                if let region = FocusRegionGeometry(
                    space: .storedReference,
                    extent: referenceExtent,
                    center: center,
                    size: size
                ) {
                    return .region(region)
                }
                return .unavailable(.centerOutsideReference)
            }
        }

        if frameRawBytes != nil, byteOrder == .bigEndian {
            // The raw frame bytes exist, but their word encoding was not verified
            // for big-endian containers. Keep the recorded centre without inventing
            // a region extent.
            if let location = FocusLocationGeometry(
                space: .storedReference,
                extent: referenceExtent,
                center: center
            ) {
                return .location(location)
            }
            return .unavailable(.centerOutsideReference)
        }

        if let location = FocusLocationGeometry(
            space: .storedReference,
            extent: referenceExtent,
            center: center
        ) {
            return .location(location)
        }
        return .unavailable(.centerOutsideReference)
    }
}
