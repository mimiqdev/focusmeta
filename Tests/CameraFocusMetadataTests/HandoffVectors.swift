// Synthetic metadata-only vectors from the sanitized format handoff.
// They contain no image bytes or identifying capture metadata.

struct SyntheticSonyVector {
    let id: String
    let hex: String
    let littleEndian: Bool
    let sonyPrefixed: Bool
    let locationWords: [UInt16]?
    let frameWords: [UInt16]?
}

struct OrientationVector {
    let id: String
    let storedExtent: (Int, Int)
    let storedCenter: (Double, Double)
    let storedSize: (Double, Double)
    let orientation: UInt16
    let displayExtent: (Int, Int)
    let displayCenter: (Double, Double)
    let displaySize: (Double, Double)
}

struct BoundaryVector {
    let id: String
    let referenceExtent: (Int, Int)
    let center: (UInt16, UInt16)
    let size: (UInt16, UInt16)
    let unclippedRect: [Double]?
}

struct SonySampleFact {
    let id: String
    let location: [UInt16]
    let frame: [UInt16]
    let location2: [UInt16]
    let modeCode: UInt8
    let areaCode: UInt8
    let arwOrientation: UInt16
    let hifIrot: UInt8
}

enum HandoffVectors {
    static let metadata: [SyntheticSonyVector] = [
        SyntheticSonyVector(
            id: "le-no-header",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f000a0006000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "le-header",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070044000000b000000002a00400010000005000000003a00400010000003c0000000000000000000000000000000000000000000000000000000000534f4e59204453432000000003001b20010001000000030000002720030004000000e60000003720070006000000ee0000000000000050003c0011001f000a0006000101",
            littleEndian: true,
            sonyPrefixed: true,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "be-no-header",
            hex:
                "4d4d002a000000080004010f0002000000050000005001100002000000090000005801120003000000010001000087690004000000010000007000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d32000000000000000000000000000000000003927c000700000038000000b0a00200040000000100000050a0030004000000010000003c00000000000000000000000000000000000000000000000000000003201b000100000001030000002027000300000004000000da2037000700000006000000e2000000000050003c0011001f000a00060101",
            littleEndian: false,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "be-header",
            hex:
                "4d4d002a000000080004010f0002000000050000005001100002000000090000005801120003000000010001000087690004000000010000007000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d32000000000000000000000000000000000003927c000700000044000000b0a00200040000000100000050a0030004000000010000003c0000000000000000000000000000000000000000000000000000534f4e5920445343200000000003201b000100000001030000002027000300000004000000e62037000700000006000000ee000000000050003c0011001f000a00060101",
            littleEndian: false,
            sonyPrefixed: true,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "frame-flag-zero",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f000a0006000000",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 0]
        ),
        SyntheticSonyVector(
            id: "frame-flag-one",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f000a0006000100",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 1]
        ),
        SyntheticSonyVector(
            id: "frame-flag-256",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f000a0006000001",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 256]
        ),
        SyntheticSonyVector(
            id: "frame-flag-65535",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f000a000600ffff",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [10, 6, 65535]
        ),
        SyntheticSonyVector(
            id: "zero-frame-dimensions",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0011001f00000000000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: [0, 0, 257]
        ),
        SyntheticSonyVector(
            id: "zero-location",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000000000000000000000a0006000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [0, 0, 0, 0],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "center-location",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c0028001e000a0006000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 40, 30],
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "location-omitted",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070024000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000002001b20010001000000030000003720070006000000ce000000000000000a0006000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: nil,
            frameWords: [10, 6, 257]
        ),
        SyntheticSonyVector(
            id: "frame-omitted",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070026000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000002001b20010001000000030000002720030004000000ce0000000000000050003c0011001f00",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 17, 31],
            frameWords: nil
        ),
        SyntheticSonyVector(
            id: "out-of-range-center",
            hex:
                "49492a000800000004000f010200050000005000000010010200090000005800000012010300010000000100000069870400010000007000000000000000000000000000000000000000000000000000534f4e5900000000494c43452d314d320000000000000000000000000000000003007c92070038000000b000000002a00400010000005000000003a00400010000003c000000000000000000000000000000000000000000000000000000000003001b20010001000000030000002720030004000000da0000003720070006000000e20000000000000050003c00ffffffff0a0006000101",
            littleEndian: true,
            sonyPrefixed: false,
            locationWords: [80, 60, 65535, 65535],
            frameWords: [10, 6, 257]
        ),
    ]

    static let orientations: [OrientationVector] = [
        OrientationVector(
            id: "exif-orientation-1",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 1,
            displayExtent: (80, 60),
            displayCenter: (16, 18),
            displaySize: (8, 12)
        ),
        OrientationVector(
            id: "exif-orientation-2",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 2,
            displayExtent: (80, 60),
            displayCenter: (64, 18),
            displaySize: (8, 12)
        ),
        OrientationVector(
            id: "exif-orientation-3",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 3,
            displayExtent: (80, 60),
            displayCenter: (64, 42),
            displaySize: (8, 12)
        ),
        OrientationVector(
            id: "exif-orientation-4",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 4,
            displayExtent: (80, 60),
            displayCenter: (16, 42),
            displaySize: (8, 12)
        ),
        OrientationVector(
            id: "exif-orientation-5",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 5,
            displayExtent: (60, 80),
            displayCenter: (18, 16),
            displaySize: (12, 8)
        ),
        OrientationVector(
            id: "exif-orientation-6",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 6,
            displayExtent: (60, 80),
            displayCenter: (42, 16),
            displaySize: (12, 8)
        ),
        OrientationVector(
            id: "exif-orientation-7",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 7,
            displayExtent: (60, 80),
            displayCenter: (42, 64),
            displaySize: (12, 8)
        ),
        OrientationVector(
            id: "exif-orientation-8",
            storedExtent: (80, 60),
            storedCenter: (16, 18),
            storedSize: (8, 12),
            orientation: 8,
            displayExtent: (60, 80),
            displayCenter: (18, 64),
            displaySize: (12, 8)
        ),
    ]

    static let boundaries: [BoundaryVector] = [
        BoundaryVector(
            id: "upper-left-edge",
            referenceExtent: (80, 60),
            center: (0, 0),
            size: (8, 12),
            unclippedRect: [-4.0, -6.0, 4.0, 6.0]
        ),
        BoundaryVector(
            id: "lower-right-edge",
            referenceExtent: (80, 60),
            center: (80, 60),
            size: (8, 12),
            unclippedRect: [76.0, 54.0, 84.0, 66.0]
        ),
        BoundaryVector(
            id: "whole-image",
            referenceExtent: (80, 60),
            center: (40, 30),
            size: (80, 60),
            unclippedRect: [0.0, 0.0, 80.0, 60.0]
        ),
        BoundaryVector(
            id: "odd-size",
            referenceExtent: (80, 60),
            center: (17, 31),
            size: (9, 7),
            unclippedRect: [12.5, 27.5, 21.5, 34.5]
        ),
        BoundaryVector(
            id: "zero-reference",
            referenceExtent: (0, 0),
            center: (0, 0),
            size: (8, 12),
            unclippedRect: nil
        ),
        BoundaryVector(
            id: "center-outside",
            referenceExtent: (80, 60),
            center: (65535, 65535),
            size: (8, 12),
            unclippedRect: nil
        ),
        BoundaryVector(
            id: "zero-size",
            referenceExtent: (80, 60),
            center: (17, 31),
            size: (0, 0),
            unclippedRect: nil
        ),
        BoundaryVector(
            id: "oversized-region",
            referenceExtent: (80, 60),
            center: (40, 30),
            size: (160, 120),
            unclippedRect: [-40.0, -30.0, 120.0, 90.0]
        ),
    ]

    static let sonyFacts: [SonySampleFact] = [
        SonySampleFact(
            id: "S01",
            location: [8640, 5760, 3402, 3588],
            frame: [446, 446, 257],
            location2: [8640, 5760, 3402, 3588],
            modeCode: 3,
            areaCode: 0,
            arwOrientation: 8,
            hifIrot: 1
        ),
        SonySampleFact(
            id: "S02",
            location: [8640, 5760, 4536, 2400],
            frame: [432, 433, 257],
            location2: [8640, 5760, 4536, 2400],
            modeCode: 3,
            areaCode: 0,
            arwOrientation: 1,
            hifIrot: 0
        ),
        SonySampleFact(
            id: "S03",
            location: [8640, 5760, 1566, 2832],
            frame: [648, 649, 257],
            location2: [8640, 5760, 1566, 2832],
            modeCode: 3,
            areaCode: 0,
            arwOrientation: 8,
            hifIrot: 1
        ),
        SonySampleFact(
            id: "S04",
            location: [8640, 5760, 1512, 912],
            frame: [2147, 1663, 257],
            location2: [8640, 5760, 1512, 912],
            modeCode: 3,
            areaCode: 0,
            arwOrientation: 8,
            hifIrot: 1
        ),
    ]
}
