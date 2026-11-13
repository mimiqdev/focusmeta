import Foundation
import Testing

@testable import CameraFocusMetadata

private enum VendorSample {
    static func url(_ name: String) -> URL? {
        guard
            let value = ProcessInfo.processInfo.environment[
                "CAMERA_FOCUS_METADATA_SAMPLES_DIR"
            ], !value.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: value, isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func read(_ name: String) throws -> FocusMetadataReport {
        guard let url = url(name) else {
            throw SampleSkip.unavailable
        }
        return try FocusMetadataReader().read(fileAt: url)
    }

    enum SampleSkip: Error {
        case unavailable
    }
}

private func record(
    _ report: FocusMetadataReport,
    tag: UInt32,
    name: String
) -> VendorRawRecord? {
    report.focus?.vendor?.records.first { $0.tag == tag && $0.name == name }
}

@Suite("Other-vendor raw observations (explicit local setting)")
struct VendorObservationTests {
    @Test(
        "Canon CR3 exposes the observed CMT3 block without pixel geometry",
        .enabled(if: VendorSample.url("P01.CR3") != nil)
    )
    func canonCR3() throws {
        let report = try VendorSample.read("P01.CR3")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .canon)
        #expect(report.focus?.geometry == .unavailable(.vendorSemanticsUnverified(vendor: .canon)))
        #expect(report.displayGeometry == nil)
        #expect(report.uncertainties.contains(.vendorGeometryUnverified))

        let prefix = try #require(
            record(report, tag: 0x0026, name: "AF information block prefix words")
        )
        #expect(
            prefix.values
                == .unsignedWords([8838, 0, 1053, 0, 5472, 3648, 5472, 3648])
        )
        let final = try #require(
            record(report, tag: 0x0026, name: "AF information block final word")
        )
        #expect(final.values == .unsignedWords([65_535]))
    }

    @Test(
        "Nikon NEF exposes the raw AF block and mode string",
        .enabled(if: VendorSample.url("P02.NEF") != nil)
    )
    func nikonNEF() throws {
        let report = try VendorSample.read("P02.NEF")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .nikon)
        #expect(report.focus?.geometry == .unavailable(.vendorSemanticsUnverified(vendor: .nikon)))
        #expect(
            record(report, tag: 0x0007, name: "Recorded focus mode string")?.values
                == .ascii("MANUAL")
        )
        guard
            case .unsignedBytes(let block)? = record(
                report,
                tag: 0x00B7,
                name: "AF information block"
            )?.values
        else {
            Issue.record("Missing Nikon AF block")
            return
        }
        #expect(block.count == 84)
        #expect(Array(block.prefix(4)) == [0x30, 0x31, 0x30, 0x31])
    }

    @Test(
        "Fujifilm RAF exposes the recorded point with an unresolved reference extent",
        .enabled(if: VendorSample.url("P03.RAF") != nil)
    )
    func fujifilmRAF() throws {
        let report = try VendorSample.read("P03.RAF")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .fujifilm)
        #expect(
            report.focus?.geometry
                == .unavailable(.referenceExtentUnresolved(vendor: .fujifilm))
        )
        #expect(
            record(report, tag: 0x1023, name: "Focus pixel word pair")?.values
                == .unsignedWords([1281, 1163])
        )
        #expect(
            record(report, tag: 0x102D, name: "Vendor tag 0x102d value")?.values
                == .unsignedWords([513])
        )
    }

    @Test(
        "Panasonic RW2 exposes the central rationals with an unverified origin",
        .enabled(if: VendorSample.url("P04.RW2") != nil)
    )
    func panasonicRW2() throws {
        let report = try VendorSample.read("P04.RW2")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .panasonic)
        #expect(
            report.focus?.geometry
                == .unavailable(.originConventionUnverified(vendor: .panasonic))
        )
        #expect(
            record(report, tag: 0x004D, name: "Recorded AF position rational pair")?.values
                == .rationals([
                    RationalValue(numerator: 128, denominator: 256),
                    RationalValue(numerator: 128, denominator: 256),
                ])
        )
        #expect(
            record(report, tag: 0x0007, name: "Recorded focus mode")?.values
                == .unsignedWords([6])
        )
    }

    @Test(
        "Olympus ORF reports empty CameraSettings storage as no region",
        .enabled(if: VendorSample.url("P05.ORF") != nil)
    )
    func olympusORF() throws {
        let report = try VendorSample.read("P05.ORF")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .olympus)
        #expect(report.focus?.geometry == .unavailable(.noRegionRecorded(vendor: .olympus)))
        guard
            case .unsignedWords(let area)? = record(
                report,
                tag: 0x0304,
                name: "Vendor tag 0x0304 values"
            )?.values
        else {
            Issue.record("Missing Olympus area storage")
            return
        }
        #expect(area.count == 64)
        #expect(area.allSatisfy { $0 == 0 })
        guard
            case .rationals(let rationals)? = record(
                report,
                tag: 0x0305,
                name: "Vendor tag 0x0305 values"
            )?.values
        else {
            Issue.record("Missing Olympus rational storage")
            return
        }
        #expect(rationals.count == 5)
        #expect(rationals.allSatisfy { $0.numerator == 0 && $0.denominator == 0 })
    }

    @Test(
        "Pentax DNG exposes selected words without claiming a pixel region",
        .enabled(if: VendorSample.url("P06.DNG") != nil)
    )
    func pentaxDNG() throws {
        let report = try VendorSample.read("P06.DNG")
        #expect(report.status == .rawVendorObservation)
        #expect(report.camera?.vendor == .pentax)
        #expect(report.container.makerNoteFlavor == .pentaxVendorPayload)
        #expect(report.focus?.geometry == .unavailable(.vendorSemanticsUnverified(vendor: .pentax)))
        #expect(
            record(report, tag: 0x000D, name: "Recorded focus mode")?.values
                == .unsignedWords([3])
        )
        #expect(
            record(report, tag: 0x000E, name: "Recorded focus point selection")?.values
                == .unsignedWords([65_534, 0])
        )
        guard
            case .unsignedBytes(let block)? = record(
                report,
                tag: 0x021F,
                name: "Vendor tag 0x021f bytes"
            )?.values
        else {
            Issue.record("Missing Pentax AF state block")
            return
        }
        #expect(block.count == 19)
    }
}
