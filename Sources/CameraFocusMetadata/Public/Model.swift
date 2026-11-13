import Foundation

/// A camera manufacturer whose metadata layouts are recognized.
public enum CameraVendor: String, Sendable, Hashable, CaseIterable {
    case sony
    case canon
    case nikon
    case fujifilm
    case panasonic
    case olympus
    case pentax
    case unknown
}

/// Camera make, model, and recorded software fields.
///
/// The software string is the value recorded in the file. It is not an
/// independent inspection of installed firmware.
public struct CameraIdentity: Sendable, Hashable {
    public let vendor: CameraVendor
    public let make: String?
    public let model: String?
    public let recordedSoftware: String?

    public init(
        vendor: CameraVendor,
        make: String?,
        model: String?,
        recordedSoftware: String?
    ) {
        self.vendor = vendor
        self.make = make
        self.model = model
        self.recordedSoftware = recordedSoftware
    }
}

/// TIFF byte order.
public enum TIFFByteOrder: String, Sendable, Hashable {
    case littleEndian
    case bigEndian
}

/// The recognized vendor payload shape inside a metadata structure.
public enum MakerNoteFlavor: String, Sendable, Hashable {
    /// Directory immediately at the MakerNote payload start. Sony's observed ARW form.
    case sonyUnprefixed
    /// Twelve-byte `SONY DSC ` prefix followed by the directory. Sony's observed HIF form.
    case sonyPrefixed
    /// Nikon prefix followed by an embedded TIFF header.
    case nikonEmbeddedTIFF
    /// `FUJIFILM` identifier followed by a MakerNote-relative directory.
    case fujifilm
    /// `Panasonic` prefix followed by a directory whose offsets use the enclosing TIFF.
    case panasonic
    /// `OLYMPUS` identifier followed by a MakerNote-relative directory.
    case olympus
    /// Pentax payload in a TIFF vendor tag rather than the Exif MakerNote.
    case pentaxVendorPayload
}

/// The container entry point that supplied the result.
public enum ContainerKind: String, Sendable, Hashable {
    case classicTIFF
    case heif
    case canonCR3
    case fujifilmRAF
    case panasonicRW2
    case olympusORF
    case jpeg
}

/// Where the metadata structure was read from.
public enum MetadataEntryPoint: Sendable, Hashable {
    case classicTIFFIFD0
    case heifMeta
    case heifExifItem(itemID: UInt32, extentLength: Int, tiffHeaderOffset: Int)
    case isoBMFFVendorBox(fourCC: String, tiffHeaderOffset: Int)
    case embeddedJPEGExif(segmentOffset: Int)
    case tiffIFD0Tag(UInt16)
}

/// A factual description of the parsed container path.
public struct ContainerDescription: Sendable, Hashable {
    public let kind: ContainerKind
    public let byteOrder: TIFFByteOrder?
    public let makerNoteFlavor: MakerNoteFlavor?
    public let entryPoint: MetadataEntryPoint

    public init(
        kind: ContainerKind,
        byteOrder: TIFFByteOrder?,
        makerNoteFlavor: MakerNoteFlavor?,
        entryPoint: MetadataEntryPoint
    ) {
        self.kind = kind
        self.byteOrder = byteOrder
        self.makerNoteFlavor = makerNoteFlavor
        self.entryPoint = entryPoint
    }
}

/// How reference tools presented a recorded frame availability word.
///
/// This is an observation of reference-tool presentation, not a camera
/// validity rule and not an autofocus-success flag.
public enum FramePresentation: String, Sendable, Hashable {
    case displayed
    case notDisplayed
    /// The word is outside the values for which presentation was observed.
    case unobserved
}

/// A recorded frame width, height, and availability-related word.
public struct RecordedFrame: Sendable, Hashable {
    public let width: UInt16
    public let height: UInt16
    public let availabilityWord: UInt16
    public let referenceToolPresentation: FramePresentation

    public init(width: UInt16, height: UInt16, availabilityWord: UInt16) {
        self.width = width
        self.height = height
        self.availabilityWord = availabilityWord
        switch availabilityWord {
        case 0:
            self.referenceToolPresentation = .notDisplayed
        case 1, 256, 257, 65_535:
            self.referenceToolPresentation = .displayed
        default:
            self.referenceToolPresentation = .unobserved
        }
    }
}

/// A recorded focus-mode code and an optional reference-tool label.
public struct RecordedMode: Sendable, Hashable {
    public let code: UInt8
    /// A label reported by reference tools for this code, when observed.
    /// The label is not an independent camera-semantics verification.
    public let referenceToolLabel: String?

    public init(code: UInt8, referenceToolLabel: String?) {
        self.code = code
        self.referenceToolLabel = referenceToolLabel
    }
}

/// A rational number exactly as recorded. No reduction or division is applied.
public struct RationalValue: Sendable, Hashable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var description: String { "\(numerator)/\(denominator)" }
}

/// Raw values retained from a vendor field.
public enum VendorRawValues: Sendable, Hashable {
    case unsignedWords([UInt64])
    case unsignedBytes([UInt8])
    case rationals([RationalValue])
    case ascii(String)
}

/// One bounded, named vendor observation.
///
/// Names describe the field's location or the handoff's neutral field name.
/// They do not add pixel semantics that were not verified.
public struct VendorRawRecord: Sendable, Hashable {
    public let tag: UInt32?
    public let name: String
    public let fieldType: UInt16?
    public let values: VendorRawValues

    public init(
        tag: UInt32?,
        name: String,
        fieldType: UInt16?,
        values: VendorRawValues
    ) {
        self.tag = tag
        self.name = name
        self.fieldType = fieldType
        self.values = values
    }
}

/// Sony fields retained from the observed MakerNote shapes.
public struct SonyFocusFields: Sendable, Hashable {
    /// The four words of tag 0x2027, when the observed SHORT[4] shape was present.
    public let locationWords: [UInt16]?
    /// The four words of tag 0x204a, when present.
    public let secondaryLocationWords: [UInt16]?
    /// The raw bytes of tag 0x2037. Three little-endian words were observed in real files.
    public let frameRawBytes: [UInt8]?
    public let mode: RecordedMode?
    /// The raw byte from tag 0x201c. Its physical meaning is not asserted.
    public let configuredAreaModeCode: UInt8?
    /// The raw bytes of tag 0x2020. All-zero real samples coexist with off-centre locations.
    public let legacyPointUseBytes: [UInt8]?
    /// Whether both location records exist and differ. Their precedence is not established.
    public let locationsDiffer: Bool?
}

/// Raw observations for vendors whose pixel geometry remains unverified.
public struct VendorFocusFields: Sendable, Hashable {
    public let vendor: CameraVendor
    public let records: [VendorRawRecord]
}

/// The recorded focus field that produced the result.
public enum FocusSource: String, Sendable, Hashable {
    case sonyLocationRecord = "Sony 0x2027 location record"
    case sonyFocusFields = "Sony MakerNote focus fields"
    case canonCR3AFInformation = "Canon CMT3 0x0026 block"
    case nikonAFInformation = "Nikon MakerNote 0x00b7 block"
    case fujifilmFocusPixel = "Fujifilm MakerNote 0x1023 word pair"
    case panasonicAFPosition = "Panasonic MakerNote 0x004d rational pair"
    case olympusCameraSettings = "Olympus CameraSettings 0x0301-0x0305"
    case pentaxFocusSelection = "Pentax vendor tag 0x000e"
}

/// A recorded focus hint and the geometry that can safely be derived from it.
///
/// The hint is a playback-zoom location field in the verified Sony scope. It is
/// not confirmed active autofocus, a successful acquisition, or image sharpness.
public struct RecordedFocus: Sendable, Hashable {
    public let source: FocusSource
    /// The reference extent recorded in the focus record itself, when present.
    public let referenceExtent: PixelExtent?
    public let geometry: FocusGeometry
    public let frame: RecordedFrame?
    public let sony: SonyFocusFields?
    public let vendor: VendorFocusFields?
}

/// The overall focus-extraction outcome.
public enum ExtractionStatus: String, Sendable, Hashable {
    /// The observed Sony location/frame shapes were parsed within the verified ILCE-1M2 scope.
    case verifiedSonyFocusMetadata
    /// Raw vendor observations are exposed, but no verified pixel geometry is claimed.
    case rawVendorObservation
    /// The container was parsed and the supported focus fields were absent.
    case focusMetadataMissing
    /// The file or its vendor focus layout is outside the supported entry points.
    case unsupported
    /// A supported entry point existed but structural validation rejected it.
    case malformed
}

/// A recoverable structural or interpretation issue.
public struct MetadataIssue: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case unrecognizedContainer
        case truncatedData
        case offsetOutOfBounds
        case arithmeticOverflow
        case invalidIFD
        case ifdCycle
        case entryCountLimitExceeded
        case metadataBudgetExceeded
        case missingExifIFD
        case missingMakerNote
        case malformedMakerNote
        case unsupportedMakerNoteLayout
        case unsupportedValueLayout
        case unexpectedFieldShape
        case duplicateTag
        case unsupportedSonyFrameByteOrder
        case referenceExtentMismatch
        case missingFocusMetadata
        case unrecognizedOrientation
        case conflictingFocusLocations
        case conflictingOrientations
        case unsupportedVendorFocusLayout
        case unsupportedHEIFLayout
        case unverifiedGeometry
        case zeroImageExtent
        case readFailure
    }

    public let kind: Kind
    public let context: String
    public let detail: String?

    public init(kind: Kind, context: String, detail: String? = nil) {
        self.kind = kind
        self.context = context
        self.detail = detail
    }
}

/// A limitation that applies to a reported value.
public enum Uncertainty: String, Sendable, Hashable {
    /// The Sony location field is described by a public reference as a playback-zoom hint.
    case playbackZoomHintIsNotConfirmedFocus
    /// A centred location cannot be distinguished from the reference's camera fallback.
    case centerMayBeCameraFallback
    /// A location does not establish active AF, successful focus, or sharpness.
    case focusSuccessNotEstablished
    /// The camera's pixel indexing and endpoint rounding are not independently proven.
    case coordinateIndexConventionUnverified
    /// Geometry uses continuous image-edge coordinates rather than camera pixel indexing.
    case continuousCoordinateApproximation
    /// The third frame word's bit meaning is unknown.
    case availabilityWordBitsUnverified
    /// The relation and precedence of 0x2027 and 0x204a are not established.
    case secondLocationRelationUnverified
    /// Both Exif and HEIF orientation sources exist, with unestablished precedence.
    case orientationPrecedenceUnestablished
    /// A HEIF primary-image transform was unsupported, invalid, or ambiguous.
    case primaryImageTransformUnsupported
    /// No orientation source was found, so display geometry was not derived.
    case displayOrientationUnknown
    /// The location record's reference extent differs from the image extent.
    case referenceExtentMismatch
    /// Big-endian frame records were not verified for real Sony cameras.
    case bigEndianFrameEncodingUnverified
    /// The vendor exposes observations whose pixel geometry is not verified.
    case vendorGeometryUnverified
    /// The mode label comes from reference tools, not an independent camera specification.
    case recordedModeLabelFromReferenceToolOnly
}

/// An input-level failure for which no report could be built.
public struct MetadataError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case cannotOpenFile
        case cannotReadFile
        case emptyInput
        case unrecognizedContainer
        case malformedContainer
        case metadataBudgetExceeded
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String {
        "CameraFocusMetadata error (\(kind.rawValue)): \(detail)"
    }
}

/// The complete read-only extraction result.
public struct FocusMetadataReport: Sendable, Hashable {
    public let status: ExtractionStatus
    public let container: ContainerDescription
    public let camera: CameraIdentity?
    /// The stored, pre-rotation image extent recorded by the container.
    public let imageExtent: PixelExtent?
    public let orientation: OrientationFacts
    public let focus: RecordedFocus?
    /// The focus geometry transformed into display space, when a single
    /// recognized orientation source exists.
    public let displayGeometry: FocusGeometry?
    public let issues: [MetadataIssue]
    public let uncertainties: [Uncertainty]
}

/// Options that bound metadata reads and structural traversal.
public struct FocusMetadataReader: Sendable {
    public struct Limits: Sendable, Hashable {
        /// Maximum bytes read for any single value or block.
        public var maximumValueBytes: Int
        /// Maximum total bytes read while parsing one file.
        public var maximumTotalReadBytes: Int
        /// Maximum entries accepted in one TIFF directory.
        public var maximumIFDEntries: Int
        /// Maximum nested TIFF directory depth.
        public var maximumIFDDepth: Int
        /// Maximum HEIF box nesting depth.
        public var maximumBoxDepth: Int
        /// Maximum declared MakerNote payload size accepted for parsing.
        public var maximumMakerNoteBytes: Int
        /// Maximum bytes examined while scanning JPEG segments for Exif.
        public var maximumJPEGScanBytes: Int

        public init(
            maximumValueBytes: Int = 8 * 1024 * 1024,
            maximumTotalReadBytes: Int = 32 * 1024 * 1024,
            maximumIFDEntries: Int = 4096,
            maximumIFDDepth: Int = 8,
            maximumBoxDepth: Int = 8,
            maximumMakerNoteBytes: Int = 4 * 1024 * 1024,
            maximumJPEGScanBytes: Int = 1024 * 1024
        ) {
            self.maximumValueBytes = maximumValueBytes
            self.maximumTotalReadBytes = maximumTotalReadBytes
            self.maximumIFDEntries = maximumIFDEntries
            self.maximumIFDDepth = maximumIFDDepth
            self.maximumBoxDepth = maximumBoxDepth
            self.maximumMakerNoteBytes = maximumMakerNoteBytes
            self.maximumJPEGScanBytes = maximumJPEGScanBytes
        }

        public static let standard = Limits()
    }

    private let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    /// Reads metadata from a local file without loading the full image payload.
    public func read(fileAt url: URL) throws -> FocusMetadataReport {
        let source: FileByteSource
        do {
            source = try FileByteSource(url: url)
        } catch {
            throw MetadataError(
                kind: .cannotOpenFile,
                detail: "The file could not be opened for metadata reads."
            )
        }
        do {
            return try ReaderEngine(limits: limits).read(source: source)
        } catch let error as MetadataError {
            throw error
        } catch {
            throw MetadataError(
                kind: .cannotReadFile,
                detail: "The file could not be read as a supported metadata container."
            )
        }
    }

    /// Reads metadata from in-memory bytes. Intended for tests and small
    /// metadata-only buffers, not for full-size originals.
    public func read(data: Data) throws -> FocusMetadataReport {
        guard !data.isEmpty else {
            throw MetadataError(kind: .emptyInput, detail: "The input was empty.")
        }
        return try ReaderEngine(limits: limits).read(source: DataByteSource(data: data))
    }
}
