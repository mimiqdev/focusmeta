import Foundation
import Testing

@testable import CameraFocusMetadata

private enum SampleAccess {
    static var directory: URL? {
        guard
            let value = ProcessInfo.processInfo.environment[
                "CAMERA_FOCUS_METADATA_SAMPLES_DIR"
            ], !value.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return url
    }

    static var isConfigured: Bool { directory != nil }

    static func file(_ name: String) -> URL? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private func requireSample(_ name: String) throws -> URL {
    try #require(SampleAccess.file(name), "Missing authorized sample \(name)")
}

@Suite("Real-sample integration (explicit local setting)")
struct RealSampleIntegrationTests {
    @Test(
        "The eight authorized Sony ARW/HIF files agree with the recorded facts",
        .enabled(if: SampleAccess.isConfigured)
    )
    func sonySamples() throws {
        let reader = FocusMetadataReader()
        for fact in HandoffVectors.sonyFacts {
            let arw = try reader.read(fileAt: try requireSample("\(fact.id).ARW"))
            let hif = try reader.read(fileAt: try requireSample("\(fact.id).HIF"))

            for (label, report) in [("ARW", arw), ("HIF", hif)] {
                #expect(
                    report.status == .verifiedSonyFocusMetadata,
                    "\(fact.id) \(label) status"
                )
                #expect(report.camera?.vendor == .sony, "\(fact.id) \(label) vendor")
                #expect(report.camera?.model == "ILCE-1M2", "\(fact.id) \(label) model")
                #expect(
                    report.camera?.recordedSoftware == "ILCE-1M2 v4.00",
                    "\(fact.id) \(label) software"
                )
                #expect(
                    report.imageExtent == PixelExtent(width: 8640, height: 5760),
                    "\(fact.id) \(label) extent"
                )
                #expect(report.issues.isEmpty, "\(fact.id) \(label) issues")
                #expect(report.focus?.referenceExtent == PixelExtent(width: 8640, height: 5760))
                #expect(report.focus?.sony?.locationWords == fact.location)
                #expect(report.focus?.sony?.secondaryLocationWords == fact.location2)
                #expect(report.focus?.sony?.locationsDiffer == false)
                #expect(report.focus?.sony?.mode?.code == fact.modeCode)
                #expect(report.focus?.sony?.mode?.referenceToolLabel == "AF-C")
                #expect(report.focus?.sony?.configuredAreaModeCode == fact.areaCode)
                #expect(
                    report.focus?.sony?.legacyPointUseBytes
                        == Array(repeating: 0, count: 10)
                )
                #expect(report.focus?.frame?.width == fact.frame[0])
                #expect(report.focus?.frame?.height == fact.frame[1])
                #expect(report.focus?.frame?.availabilityWord == fact.frame[2])
                #expect(report.focus?.frame?.referenceToolPresentation == .displayed)
                #expect(report.uncertainties.contains(.playbackZoomHintIsNotConfirmedFocus))
                #expect(report.uncertainties.contains(.focusSuccessNotEstablished))
                #expect(report.uncertainties.contains(.coordinateIndexConventionUnverified))
                #expect(report.uncertainties.contains(.availabilityWordBitsUnverified))
                #expect(report.uncertainties.contains(.secondLocationRelationUnverified))
                #expect(report.uncertainties.contains(.continuousCoordinateApproximation))

                guard case .region(let geometry)? = report.focus?.geometry else {
                    Issue.record("\(fact.id) \(label) did not expose a region")
                    continue
                }
                #expect(geometry.center.x == Double(fact.location[2]))
                #expect(geometry.center.y == Double(fact.location[3]))
                #expect(geometry.size.width == Double(fact.frame[0]))
                #expect(geometry.size.height == Double(fact.frame[1]))
                #expect(
                    geometry.normalizedCenter.x
                        == Double(fact.location[2]) / 8640.0
                )
                #expect(
                    geometry.normalizedCenter.y
                        == Double(fact.location[3]) / 5760.0
                )
                #expect(!geometry.extendsBeyondExtent)
            }

            #expect(arw.container.makerNoteFlavor == .sonyUnprefixed)
            #expect(hif.container.makerNoteFlavor == .sonyPrefixed)
            #expect(arw.container.kind == .classicTIFF)
            #expect(hif.container.kind == .heif)
            #expect(arw.orientation.exif?.rawValue == fact.arwOrientation)
            #expect(arw.orientation.resolution == .exifOnly)
            #expect(hif.orientation.exif == nil)
            #expect(hif.orientation.primaryImageRotation?.rawPayload == fact.hifIrot)
            #expect(hif.orientation.resolution == .primaryImageRotationOnly)
            if fact.hifIrot == 1 {
                #expect(hif.orientation.primaryImageRotation?.clockwiseDegrees == 270)
                #expect(hif.orientation.displayTransform == .rotate270Clockwise)
            } else {
                #expect(hif.orientation.primaryImageRotation?.clockwiseDegrees == 0)
                #expect(hif.orientation.displayTransform == .identity)
            }

            guard
                case .heifExifItem(_, let extentLength, let tiffHeaderOffset) =
                    hif.container.entryPoint
            else {
                Issue.record("\(fact.id) HIF did not expose an Exif item entry point")
                continue
            }
            #expect(extentLength == 94_208)
            #expect(tiffHeaderOffset == 10)

            #expect(arw.focus?.sony?.locationWords == hif.focus?.sony?.locationWords)
            #expect(arw.focus?.sony?.secondaryLocationWords == hif.focus?.sony?.secondaryLocationWords)
            #expect(arw.focus?.frame == hif.focus?.frame)
            #expect(arw.focus?.geometry == hif.focus?.geometry)
            #expect(arw.displayGeometry == hif.displayGeometry)
            #expect(arw.imageExtent == hif.imageExtent)

            guard case .region(let arwDisplay)? = arw.displayGeometry,
                case .region(let hifDisplay)? = hif.displayGeometry
            else {
                Issue.record("\(fact.id) did not expose display geometry")
                continue
            }
            let expectedDisplayExtent =
                fact.arwOrientation >= 5
                ? PixelExtent(width: 5760, height: 8640)
                : PixelExtent(width: 8640, height: 5760)
            #expect(arwDisplay.extent == expectedDisplayExtent)
            #expect(arwDisplay.center == hifDisplay.center)
            #expect(arwDisplay.size == hifDisplay.size)
        }
    }

    @Test(
        "A verified-scope absence does not fabricate a focus centre",
        .enabled(if: SampleAccess.file("P07.ARW") != nil)
    )
    func manualSonyAbsence() throws {
        let report = try FocusMetadataReader().read(fileAt: try requireSample("P07.ARW"))
        #expect(report.status == .focusMetadataMissing)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
        #expect(report.issues.contains { $0.kind == .missingFocusMetadata })
    }

    @Test(
        "A Canon JPEG without a supported AF layout stays unsupported",
        .enabled(if: SampleAccess.file("P08.JPG") != nil)
    )
    func canonJPEGAbsence() throws {
        let report = try FocusMetadataReader().read(fileAt: try requireSample("P08.JPG"))
        #expect(report.status == .unsupported)
        #expect(report.focus == nil)
        #expect(report.displayGeometry == nil)
    }
}
