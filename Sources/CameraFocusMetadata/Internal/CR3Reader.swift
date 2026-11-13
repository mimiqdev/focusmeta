import Foundation

enum CR3Reader {
    private static let canonUUID: [UInt8] = [
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
    ]

    static func extract(
        reader: BoundedReader,
        builder: ExtractionBuilder,
        limits: FocusMetadataReader.Limits
    ) {
        do {
            guard let cmt3 = try findCMT3(reader: reader, limits: limits) else {
                builder.focusPathUnsupported = true
                builder.addIssue(
                    .unsupportedVendorFocusLayout,
                    context: "Canon CR3",
                    detail: "The known CMT3 vendor box was not found."
                )
                return
            }
            if builder.camera == nil {
                builder.camera = CameraIdentity(
                    vendor: .canon,
                    make: nil,
                    model: nil,
                    recordedSoftware: nil
                )
            }
            let header = try TIFFHeaderParser.read(
                reader: reader,
                at: cmt3.payloadStart,
                regionEnd: cmt3.end
            )
            TIFFMetadataExtractor.extract(
                reader: reader,
                options: TIFFExtractionOptions(
                    containerKind: .canonCR3,
                    entryPoint: .isoBMFFVendorBox(
                        fourCC: "CMT3",
                        tiffHeaderOffset: 0
                    ),
                    base: cmt3.payloadStart,
                    regionEnd: cmt3.end,
                    byteOrder: header.byteOrder,
                    firstIFDOffset: header.firstIFDOffset,
                    parseMakerNote: false,
                    parsePentaxVendorPayload: false,
                    parseCanonVendorBlock: true
                ),
                builder: builder,
                limits: limits
            )
        } catch let failure as ParseFailure {
            builder.focusPathUnsupported = true
            builder.addIssue(failure: failure, context: "Canon CR3")
        } catch {
            builder.focusPathUnsupported = true
        }
    }

    private static func findCMT3(
        reader: BoundedReader,
        limits: FocusMetadataReader.Limits
    ) throws -> BMFFBox? {
        var counter = 0
        var moov: BMFFBox?
        try BMFFParser.forEachBox(
            reader: reader,
            start: 0,
            end: reader.length,
            depth: 0,
            limits: limits,
            boxCounter: &counter
        ) { box in
            if box.type == "moov" {
                moov = box
            }
        }
        guard let moov else { return nil }

        var uuidBox: BMFFBox?
        var innerCounter = 0
        try BMFFParser.forEachBox(
            reader: reader,
            start: moov.payloadStart,
            end: moov.end,
            depth: 1,
            limits: limits,
            boxCounter: &innerCounter
        ) { box in
            guard box.type == "uuid",
                box.payloadLength >= 16,
                uuidBox == nil
            else { return }
            let identifier = try reader.read(at: box.payloadStart, count: 16)
            if identifier == canonUUID {
                uuidBox = box
            }
        }
        guard let uuidBox else { return nil }

        var cmt3: BMFFBox?
        var vendorCounter = 0
        try BMFFParser.forEachBox(
            reader: reader,
            start: uuidBox.payloadStart + 16,
            end: uuidBox.end,
            depth: 2,
            limits: limits,
            boxCounter: &vendorCounter
        ) { box in
            if box.type == "CMT3", cmt3 == nil {
                cmt3 = box
            }
        }
        return cmt3
    }
}
