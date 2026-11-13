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
