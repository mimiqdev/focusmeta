import Foundation
import Testing

@testable import CameraFocusMetadata

@Suite("Input boundary and resource limits")
struct ErrorAndLimitTests {
    private func vector(_ id: String) throws -> [UInt8] {
        let value = try #require(HandoffVectors.metadata.first { $0.id == id })
        return TestSupport.bytes(hex: value.hex)
    }

    @Test("Empty input is rejected")
    func emptyInput() {
        do {
            _ = try FocusMetadataReader().read(data: Data())
            Issue.record("Expected empty input to throw")
        } catch let error as MetadataError {
            #expect(error.kind == .emptyInput)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("Unrecognized bytes are rejected")
    func unrecognizedContainer() {
        do {
            _ = try FocusMetadataReader().read(data: Data([0x00, 0x01, 0x02, 0x03]))
            Issue.record("Expected an unrecognized container")
        } catch let error as MetadataError {
            #expect(error.kind == .unrecognizedContainer)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("An unreadable local path is reported without embedding the path")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/camera-focus-metadata-test-input")
        do {
            _ = try FocusMetadataReader().read(fileAt: url)
            Issue.record("Expected a missing file error")
        } catch let error as MetadataError {
            #expect(error.kind == .cannotOpenFile)
            #expect(!error.description.contains(url.path))
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("A directory cycle is rejected")
    func ifdCycle() throws {
        var bytes = try vector("le-no-header")
        let ifd0 = Int(TestSupport.readUInt32(bytes, at: 4, order: .littleEndian))
        let count = Int(TestSupport.readUInt16(bytes, at: ifd0, order: .littleEndian))
        var found = false
        for index in 0..<count {
            let entry = ifd0 + 2 + index * 12
            if TestSupport.readUInt16(bytes, at: entry, order: .littleEndian) == 0x8769 {
                TestSupport.writeUInt32(
                    UInt32(ifd0),
                    to: &bytes,
                    at: entry + 8,
                    order: .littleEndian
                )
                found = true
            }
        }
        #expect(found)
        let report = try FocusMetadataReader().read(data: Data(bytes))
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .invalidIFD })
    }

    @Test("The per-parse read budget stops traversal")
    func readBudget() throws {
        let reader = FocusMetadataReader(
            limits: FocusMetadataReader.Limits(maximumTotalReadBytes: 20)
        )
        let report = try reader.read(data: Data(try vector("le-no-header")))
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .metadataBudgetExceeded })
        #expect(report.focus == nil)
    }

    @Test("The directory entry limit stops traversal")
    func entryLimit() throws {
        let reader = FocusMetadataReader(
            limits: FocusMetadataReader.Limits(maximumIFDEntries: 2)
        )
        let report = try reader.read(data: Data(try vector("le-no-header")))
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .entryCountLimitExceeded })
        #expect(report.focus == nil)
    }

    @Test("A recognized but truncated TIFF header produces a malformed report")
    func truncatedTIFFHeader() throws {
        let bytes = Array(try vector("le-no-header").prefix(4))
        let report = try FocusMetadataReader().read(data: Data(bytes))
        #expect(report.status == .malformed)
        #expect(report.issues.contains { $0.kind == .truncatedData })
    }
}
