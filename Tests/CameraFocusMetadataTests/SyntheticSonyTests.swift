import Foundation
import Testing

@testable import CameraFocusMetadata

private func parse(_ bytes: [UInt8]) throws -> FocusMetadataReport {
    try FocusMetadataReader().read(data: Data(bytes))
}

@Suite("Synthetic Sony metadata vectors")
struct SyntheticSonyTests {
    @Test("Recorded words and explicit geometry outcomes")
    func metadataVectors() throws {
        for vector in HandoffVectors.metadata {
            let report = try parse(TestSupport.bytes(hex: vector.hex))
            #expect(report.camera?.vendor == .sony, "\(vector.id)")
            #expect(report.camera?.model == "ILCE-1M2", "\(vector.id)")
            #expect(report.container.byteOrder == (vector.littleEndian ? .littleEndian : .bigEndian))
            #expect(
                report.container.makerNoteFlavor
                    == (vector.sonyPrefixed ? .sonyPrefixed : .sonyUnprefixed),
                "\(vector.id)"
            )
            #expect(report.imageExtent == PixelExtent(width: 80, height: 60), "\(vector.id)")

            switch vector.id {
            case "be-no-header", "be-header":
                #expect(report.status == .verifiedSonyFocusMetadata)
                #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
                #expect(report.focus?.frame == nil)
                #expect(report.uncertainties.contains(.bigEndianFrameEncodingUnverified))
                #expect(report.issues.contains { $0.kind == .unsupportedSonyFrameByteOrder })
                #expect(report.focus?.geometry.isLocation == true)
                let location = try #require(report.focus?.geometry)
                guard case .location(let geometry) = location else {
                    Issue.record("Expected a location-only geometry")
                    continue
                }
                #expect(geometry.center == ContinuousPoint(x: 17, y: 31))
                #expect(geometry.normalizedCenter == NormalizedPoint(x: 17.0 / 80.0, y: 31.0 / 60.0))
            default:
                #expect(report.status == .verifiedSonyFocusMetadata, "\(vector.id)")
                if let words = vector.locationWords {
                    #expect(report.focus?.sony?.locationWords == words, "\(vector.id)")
                }
                if let frameWords = vector.frameWords {
                    #expect(report.focus?.frame?.width == frameWords[0], "\(vector.id)")
                    #expect(report.focus?.frame?.height == frameWords[1], "\(vector.id)")
                    #expect(report.focus?.frame?.availabilityWord == frameWords[2], "\(vector.id)")
                } else {
                    #expect(report.focus?.frame == nil, "\(vector.id)")
                }
            }
        }
    }

    @Test("Explicit per-vector geometry")
    func vectorSpecificGeometry() throws {
        func report(_ id: String) throws -> FocusMetadataReport {
            let vector = try #require(HandoffVectors.metadata.first { $0.id == id })
            return try parse(TestSupport.bytes(hex: vector.hex))
        }

        for id in ["le-no-header", "le-header", "frame-flag-one", "frame-flag-256", "frame-flag-65535"] {
            let value = try report(id)
            guard case .region(let geometry)? = value.focus?.geometry else {
                Issue.record("Expected a region for \(id)")
                continue
            }
            #expect(geometry.unclippedRect == ContinuousRect(minX: 12, minY: 28, maxX: 22, maxY: 34))
            #expect(geometry.extendsBeyondExtent == false)
        }

        let zeroFlag = try report("frame-flag-zero")
        #expect(zeroFlag.focus?.frame?.referenceToolPresentation == .notDisplayed)
        #expect(
            zeroFlag.focus?.geometry
                == .unavailable(.frameNotPresentedByReferenceTools)
        )

        let zeroFrame = try report("zero-frame-dimensions")
        #expect(zeroFrame.focus?.geometry == .unavailable(.zeroRegionExtent))

        let zeroLocation = try report("zero-location")
        #expect(zeroLocation.focus?.sony?.locationWords == [0, 0, 0, 0])
        #expect(zeroLocation.focus?.geometry == .unavailable(.zeroReferenceExtent))

        let center = try report("center-location")
        guard case .region(let centerGeometry)? = center.focus?.geometry else {
            Issue.record("Expected a centred region")
            return
        }
        #expect(centerGeometry.normalizedCenter == NormalizedPoint(x: 0.5, y: 0.5))
        #expect(center.uncertainties.contains(.centerMayBeCameraFallback))

        let omittedLocation = try report("location-omitted")
        #expect(omittedLocation.focus?.sony?.locationWords == nil)
        #expect(omittedLocation.focus?.frame != nil)
        #expect(omittedLocation.focus?.geometry == .unavailable(.noLocationRecorded))

        let omittedFrame = try report("frame-omitted")
        #expect(omittedFrame.focus?.frame == nil)
        #expect(omittedFrame.focus?.geometry.isLocation == true)

        let outside = try report("out-of-range-center")
        #expect(outside.focus?.sony?.locationWords == [80, 60, 65535, 65535])
        #expect(outside.focus?.geometry == .unavailable(.centerOutsideReference))

        for id in ["le-no-header", "frame-flag-one"] {
            let value = try report(id)
            #expect(value.uncertainties.contains(.playbackZoomHintIsNotConfirmedFocus))
            #expect(value.uncertainties.contains(.focusSuccessNotEstablished))
            #expect(value.uncertainties.contains(.coordinateIndexConventionUnverified))
            #expect(value.uncertainties.contains(.continuousCoordinateApproximation))
        }
    }

    @Test("Truncated location payload is rejected")
    func truncatedLocationPayload() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        let valueOffset = try editor.valueOffset(tag: 0x2027)
        editor.bytes = Array(editor.bytes.prefix(valueOffset + 6))
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(
            report.issues.contains {
                $0.kind == .offsetOutOfBounds || $0.kind == .truncatedData
            }
        )
        #expect(report.focus?.geometry.isRegion != true)
    }

    @Test("A truncated frame payload is rejected without losing the location")
    func truncatedFramePayload() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        let valueOffset = try editor.valueOffset(tag: 0x2037)
        editor.setMakerNoteDeclaredLength(
            UInt32(valueOffset + 4 - editor.makerNoteOffset)
        )
        editor.bytes = Array(editor.bytes.prefix(valueOffset + 4))
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(
            report.issues.contains {
                $0.kind == .offsetOutOfBounds || $0.kind == .truncatedData
            }
        )
        #expect(report.focus?.frame == nil)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.focus?.geometry.isLocation == true)
    }

    @Test("A three-word location is not treated as the observed shape")
    func locationCountThree() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setEntryCount(3, tag: 0x2027)
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .unexpectedFieldShape })
        #expect(report.focus?.sony?.locationWords == nil)
        #expect(report.focus?.frame?.width == 10)
        #expect(report.focus?.geometry == .unavailable(.noLocationRecorded))
    }

    @Test("A non-UNDEFINED frame record is rejected")
    func frameShortType() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setEntryType(3, tag: 0x2037)
        try editor.setEntryCount(3, tag: 0x2037)
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .unexpectedFieldShape })
        #expect(report.focus?.frame == nil)
        #expect(report.focus?.geometry.isLocation == true)
    }

    @Test("An out-of-bounds value offset is rejected")
    func outOfBoundsOffset() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setEntryOffset(UInt32(editor.bytes.count - 4), tag: 0x2027)
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .offsetOutOfBounds })
        #expect(report.focus?.geometry.isRegion != true)
    }

    @Test("An overflowing value offset is rejected")
    func overflowingOffset() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setEntryOffset(0xFFFF_FFFE, tag: 0x2027)
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(
            report.issues.contains {
                $0.kind == .offsetOutOfBounds || $0.kind == .arithmeticOverflow
            }
        )
        #expect(report.focus?.geometry.isRegion != true)
    }

    @Test("An unknown availability word does not create a region")
    func unknownAvailabilityWord() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setWords([10, 6, 999], tag: 0x2037)
        let report = try parse(editor.bytes)
        #expect(report.focus?.frame?.availabilityWord == 999)
        #expect(report.focus?.frame?.referenceToolPresentation == .unobserved)
        #expect(
            report.focus?.geometry == .unavailable(.frameAvailabilityWordUnverified(999))
        )
        #expect(report.focus?.geometry.isRegion == false)
    }

    @Test("Differing location records are preserved with an explicit conflict")
    func conflictingLocations() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-no-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        let frameValueOffset = try editor.valueOffset(tag: 0x2037)
        try editor.setEntryTag(0x204A, tag: 0x2037)
        try editor.setEntryType(3, tag: 0x204A)
        try editor.setEntryCount(4, tag: 0x204A)
        editor.appendBytes([0, 0])
        try editor.setEntryOffset(UInt32(frameValueOffset), tag: 0x204A)
        try editor.setWords([80, 60, 40, 30], tag: 0x204A)
        let report = try parse(editor.bytes)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.focus?.sony?.secondaryLocationWords == [80, 60, 40, 30])
        #expect(report.focus?.sony?.locationsDiffer == true)
        #expect(report.issues.contains { $0.kind == .conflictingFocusLocations })
        #expect(report.uncertainties.contains(.secondLocationRelationUnverified))
        #expect(report.focus?.geometry.isLocation == true)
    }

    @Test("A Sony MakerNote without a location or frame does not fabricate a centre")
    func sonyWithoutHint() throws {
        let tiff = TestTIFFBuilder(
            orientation: 1,
            imageExtent: (80, 60),
            makerNote: TestSupport.sonyMakerNote()
        ).build()
        let report = try parse(tiff)
        #expect(report.status == .focusMetadataMissing)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .missingFocusMetadata })
        #expect(report.uncertainties.contains(.displayOrientationUnknown) == false)
    }

    @Test("The declared MakerNote extent bounds the Sony directory table")
    func makerNoteTableBound() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        // Prefix + count + two complete entries + half of the third entry.
        editor.setMakerNoteDeclaredLength(44)
        let report = try parse(editor.bytes)
        #expect(report.status == .malformed)
        #expect(report.focus == nil)
        #expect(
            report.issues.contains {
                $0.kind == .truncatedData || $0.kind == .malformedMakerNote
            }
        )
    }

    @Test("An unrecognized Exif orientation never produces display geometry")
    func unrecognizedExifOrientation() throws {
        let vector = try #require(HandoffVectors.metadata.first { $0.id == "le-header" })
        var editor = try SonyVectorEditor(hex: vector.hex)
        try editor.setIFD0Orientation(9)
        let report = try parse(editor.bytes)
        #expect(report.focus?.geometry.isRegion == true)
        #expect(report.orientation.exif?.rawValue == 9)
        #expect(report.orientation.resolution == .unrecognized)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .unrecognizedOrientation })
    }

    @Test("A missing orientation does not produce display geometry")
    func missingOrientation() throws {
        let tiff = TestTIFFBuilder(
            orientation: nil,
            imageExtent: (80, 60),
            makerNote: TestSupport.sonyMakerNote()
        ).build()
        let report = try parse(tiff)
        #expect(report.orientation.resolution == .none)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.uncertainties.contains(.displayOrientationUnknown))
    }
}
