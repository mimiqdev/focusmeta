import Foundation
import Testing

@testable import CameraFocusMetadata

private func parse(_ bytes: [UInt8]) throws -> FocusMetadataReport {
    try FocusMetadataReader().read(data: Data(bytes))
}

private func baseTIFF(
    orientation: UInt16? = nil,
    makerNote: [UInt8]? = nil
) -> [UInt8] {
    TestTIFFBuilder(
        orientation: orientation,
        imageExtent: (80, 60),
        makerNote: makerNote ?? TestSupport.sonyMakerNote(prefixed: true)
    ).build()
}

@Suite("HEIF Exif item and primary-image rotation")
struct HEIFStructureTests {
    @Test("The Exif item displacement origin is after its four-byte field")
    func exifOrigin() throws {
        let tiff = baseTIFF()
        let heif = TestHEIFBuilder(exifTIFF: tiff, irotPayload: 1).build()
        let report = try parse(heif)

        #expect(report.container.kind == .heif)
        #expect(report.container.makerNoteFlavor == .sonyPrefixed)
        #expect(report.imageExtent == PixelExtent(width: 80, height: 60))
        #expect(report.orientation.resolution == .primaryImageRotationOnly)
        #expect(report.orientation.primaryImageRotation?.rawPayload == 1)
        #expect(report.orientation.primaryImageRotation?.clockwiseDegrees == 270)
        #expect(report.orientation.displayTransform == .rotate270Clockwise)
        #expect(report.orientation.displayExtent == PixelExtent(width: 60, height: 80))
        #expect(report.status == .focusMetadataMissing)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)

        guard
            case .heifExifItem(let itemID, let extentLength, let tiffHeaderOffset) =
                report.container.entryPoint
        else {
            Issue.record("Expected a HEIF Exif item entry point")
            return
        }
        #expect(itemID == 14)
        #expect(tiffHeaderOffset == 10)
        #expect(extentLength == 4 + 6 + tiff.count)
    }

    @Test("Only the irot associated with the primary item is applied")
    func rotationAssociation() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            irotPayload: 1,
            extraProperties: [.init(type: "irot", payload: [0])],
            primaryAssociations: [1, 3],
            additionalAssociations: [(item: 31, indices: [2])]
        ).build()
        let report = try parse(heif)
        #expect(report.orientation.primaryImageRotation?.rawPayload == 0)
        #expect(report.orientation.displayTransform == .identity)
        #expect(report.orientation.displayExtent == PixelExtent(width: 80, height: 60))
    }

    @Test("Exif and HEIF orientation coexistence keeps both and blocks display geometry")
    func orientationConflict() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: baseTIFF(orientation: 6),
            irotPayload: 1
        ).build()
        let report = try parse(heif)
        #expect(report.orientation.exif?.rawValue == 6)
        #expect(report.orientation.primaryImageRotation?.rawPayload == 1)
        #expect(report.orientation.resolution == .multipleSourcesUnverified)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .conflictingOrientations })
        #expect(report.uncertainties.contains(.orientationPrecedenceUnestablished))
    }

    @Test("A multi-extent Exif item is explicitly unsupported")
    func multiExtentExifItem() throws {
        let builder = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            extentCount: 2,
            secondExtent: (offset: 8192, length: 8)
        )
        let report = try parse(builder.build())
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
    }

    @Test("A nonzero iloc base offset is explicitly unsupported")
    func nonzeroBaseOffset() throws {
        let builder = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            baseOffset: 100,
            baseOffsetSize: 4
        )
        let report = try parse(builder.build())
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
    }

    @Test("An external Exif data reference is explicitly unsupported")
    func externalDataReference() throws {
        let builder = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            dataReferenceIndex: 1
        )
        let report = try parse(builder.build())
        #expect(report.status == .unsupported)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
    }

    @Test("A construction method other than zero is explicitly unsupported")
    func nonzeroConstructionMethod() throws {
        let builder = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            constructionMethod: 1
        )
        let report = try parse(builder.build())
        #expect(report.status == .unsupported)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
    }

    @Test("An Exif extent outside the file is rejected")
    func exifExtentOutsideFile() throws {
        let builder = TestHEIFBuilder(
            exifTIFF: baseTIFF(),
            extentOverride: (offset: 4096, length: 1_000_000)
        )
        let report = try parse(builder.build())
        #expect(report.status == .unsupported)
        #expect(report.issues.contains { $0.kind == .offsetOutOfBounds })
        #expect(report.focus == nil)
    }

    @Test("A TIFF value that escapes the Exif item region is rejected")
    func valueOutsideExifItem() throws {
        let fullTIFF = baseTIFF()
        let truncatedTIFF = Array(fullTIFF.prefix(100))
        let report = try parse(
            TestHEIFBuilder(exifTIFF: truncatedTIFF).build()
        )
        #expect(report.status == .malformed || report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(
            report.issues.contains {
                $0.kind == .offsetOutOfBounds || $0.kind == .truncatedData
                    || $0.kind == .invalidIFD
            }
        )
    }
}

private enum FocusFixtureError: Error {
    case missingVector
}

/// Synthetic Sony1 TIFF carrying real focus fields, with a chosen Exif orientation.
private func focusBearingTIFF(orientation: UInt16) throws -> [UInt8] {
    guard let vector = HandoffVectors.metadata.first(where: { $0.id == "le-header" }) else {
        throw FocusFixtureError.missingVector
    }
    var editor = try SonyVectorEditor(hex: vector.hex)
    try editor.setIFD0Orientation(orientation)
    return editor.bytes
}

extension HEIFStructureTests {
    @Test("An associated imir suppresses the Exif-only display fallback")
    func imirSuppressesExifFallback() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 6),
            irotPayload: nil,
            extraProperties: [.init(type: "imir", payload: [0])],
            primaryAssociations: [1, 2]
        ).build()
        let report = try parse(heif)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.focus?.frame?.width == 10)
        #expect(report.focus?.geometry.isRegion == true)
        #expect(report.orientation.exif?.rawValue == 6)
        #expect(report.orientation.resolution == .unsupportedPrimaryImageTransform)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
        #expect(report.uncertainties.contains(.primaryImageTransformUnsupported))
        #expect(report.status == .verifiedSonyFocusMetadata)
    }

    @Test("An associated clap suppresses the Exif-only display fallback")
    func clapSuppressesExifFallback() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 6),
            irotPayload: nil,
            extraProperties: [.init(type: "clap", payload: Array(repeating: 0, count: 32))],
            primaryAssociations: [1, 2]
        ).build()
        let report = try parse(heif)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.focus?.geometry.isRegion == true)
        #expect(report.orientation.exif?.rawValue == 6)
        #expect(report.orientation.resolution == .unsupportedPrimaryImageTransform)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .unsupportedHEIFLayout })
        #expect(report.uncertainties.contains(.primaryImageTransformUnsupported))
        #expect(report.status == .verifiedSonyFocusMetadata)
    }

    @Test("An Exif item without a cdsc association is unsupported")
    func exifItemWithoutCDSC() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 1),
            irotPayload: 1,
            includeCDSC: false
        ).build()
        let report = try parse(heif)
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
        #expect(
            report.issues.contains {
                $0.kind == .unsupportedHEIFLayout && $0.context == "HEIF Exif item cdsc"
            }
        )
    }

    @Test("An Exif item with an ambiguous cdsc target is unsupported")
    func exifItemAmbiguousCDSC() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 1),
            primaryItemID: 30,
            irotPayload: 1,
            cdscTargets: [30, 31]
        ).build()
        let report = try parse(heif)
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
        #expect(
            report.issues.contains {
                $0.kind == .unsupportedHEIFLayout && $0.context == "HEIF Exif item cdsc"
            }
        )
    }

    @Test("Multiple associated irot properties are ambiguous and suppress display")
    func multipleAssociatedIROT() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 6),
            irotPayload: 1,
            extraProperties: [.init(type: "irot", payload: [0])],
            primaryAssociations: [1, 2, 3]
        ).build()
        let report = try parse(heif)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.orientation.exif?.rawValue == 6)
        #expect(report.orientation.primaryImageRotation == nil)
        #expect(report.orientation.resolution == .unsupportedPrimaryImageTransform)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.uncertainties.contains(.primaryImageTransformUnsupported))
    }

    @Test("An imir not associated with the primary does not suppress Exif orientation")
    func unassociatedIMIRDoesNotSuppress() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 6),
            irotPayload: nil,
            extraProperties: [.init(type: "imir", payload: [0])],
            primaryAssociations: [1],
            additionalAssociations: [(item: 31, indices: [2])]
        ).build()
        let report = try parse(heif)
        #expect(report.orientation.resolution == .exifOnly)
        #expect(report.orientation.displayTransform == .rotate90Clockwise)
        #expect(report.displayGeometry != nil)
        #expect(report.uncertainties.contains(.primaryImageTransformUnsupported) == false)
    }

    @Test("An invalid primary irot payload never produces display geometry")
    func invalidIROTPayload() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 1),
            irotPayload: 4
        ).build()
        let report = try parse(heif)
        #expect(report.focus?.sony?.locationWords == [80, 60, 17, 31])
        #expect(report.orientation.primaryImageRotation?.rawPayload == 4)
        #expect(report.orientation.primaryImageRotation?.transform == nil)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .unrecognizedOrientation })
    }

    @Test("An invalid irot without Exif orientation is unrecognized")
    func invalidIROTOnly() throws {
        let tiff = TestTIFFBuilder(
            orientation: nil,
            imageExtent: (80, 60),
            makerNote: TestSupport.sonyMakerNote(prefixed: true)
        ).build()
        let report = try parse(TestHEIFBuilder(exifTIFF: tiff, irotPayload: 7).build())
        #expect(report.orientation.primaryImageRotation?.rawPayload == 7)
        #expect(report.orientation.primaryImageRotation?.transform == nil)
        #expect(report.orientation.resolution == .unrecognized)
        #expect(report.orientation.displayTransform == nil)
        #expect(report.displayGeometry == nil)
    }

    @Test("An Exif item linked to a non-primary item is not used")
    func exifItemLinkedElsewhere() throws {
        let heif = TestHEIFBuilder(
            exifTIFF: try focusBearingTIFF(orientation: 1),
            primaryItemID: 30,
            irotPayload: 1,
            cdscTargets: [31]
        ).build()
        let report = try parse(heif)
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
        #expect(
            report.issues.contains {
                $0.kind == .unsupportedHEIFLayout && $0.context == "HEIF Exif item cdsc"
            }
        )
    }
}
