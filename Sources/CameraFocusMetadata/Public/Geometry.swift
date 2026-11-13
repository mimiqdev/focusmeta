import Foundation

/// A positive pixel width and height.
///
/// Dimensions are recorded metadata values. They are not measured from decoded
/// pixels by this library.
public struct PixelExtent: Sendable, Hashable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    /// Creates an extent only when both dimensions are positive.
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// A point in continuous image coordinates.
///
/// Coordinates increase rightward and downward from the upper-left corner.
/// Values describe positions on a continuous plane; they do not identify a
/// sensor pixel centre.
public struct ContinuousPoint: Sendable, Hashable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(x), \(y))" }
}

/// A width and height on a continuous plane.
public struct ContinuousSize: Sendable, Hashable, CustomStringConvertible {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// An unclipped rectangle on a continuous plane.
public struct ContinuousRect: Sendable, Hashable, CustomStringConvertible {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public var description: String { "(\(minX), \(minY), \(maxX), \(maxY))" }
}

/// A point expressed as fractions of a reference extent.
public struct NormalizedPoint: Sendable, Hashable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(x), \(y))" }
}

/// A size expressed as fractions of a reference extent.
public struct NormalizedSize: Sendable, Hashable, CustomStringConvertible {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// An unclipped rectangle expressed as fractions of a reference extent.
public struct NormalizedRect: Sendable, Hashable, CustomStringConvertible {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var description: String { "(\(minX), \(minY), \(maxX), \(maxY))" }
}

/// The coordinate approximation used by the geometry results.
public enum CoordinateModel: String, Sendable, Hashable {
    /// Continuous coordinates measured in from the upper-left image edges.
    ///
    /// This is a geometric approximation. It does not assert the camera's
    /// zero-based or one-based pixel indexing, subpixel rounding, or sensor-site
    /// correspondence.
    case continuousEdgeCoordinatesFromUpperLeft
}

/// The image space in which a geometry value is expressed.
public enum GeometrySpace: String, Sendable, Hashable {
    /// The recorded reference space before display rotation.
    case storedReference

    /// The display orientation produced by the recorded transform.
    case display
}

/// A safe recorded focus region or location, or an explicit reason it is unavailable.
public enum FocusGeometry: Sendable, Hashable {
    case region(FocusRegionGeometry)
    case location(FocusLocationGeometry)
    case unavailable(FocusGeometryUnavailability)

    public var isRegion: Bool {
        if case .region = self { return true }
        return false
    }

    public var isLocation: Bool {
        if case .location = self { return true }
        return false
    }

    public var isAvailable: Bool {
        switch self {
        case .region, .location:
            return true
        case .unavailable:
            return false
        }
    }
}

/// A closeable focus region backed by recorded dimensions and coordinates.
public struct FocusRegionGeometry: Sendable, Hashable {
    public let space: GeometrySpace
    public let extent: PixelExtent
    public let center: ContinuousPoint
    public let size: ContinuousSize
    public let unclippedRect: ContinuousRect
    public let normalizedCenter: NormalizedPoint
    public let normalizedSize: NormalizedSize
    public let normalizedUnclippedRect: NormalizedRect
    public let coordinateModel: CoordinateModel
    public let extendsBeyondExtent: Bool

    init?(
        space: GeometrySpace,
        extent: PixelExtent,
        center: ContinuousPoint,
        size: ContinuousSize
    ) {
        let width = Double(extent.width)
        let height = Double(extent.height)
        let tolerance = 1e-9
        guard center.x.isFinite, center.y.isFinite,
            size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0,
            center.x >= -tolerance, center.x <= width + tolerance,
            center.y >= -tolerance, center.y <= height + tolerance
        else { return nil }

        let rect = ContinuousRect(
            minX: center.x - size.width / 2,
            minY: center.y - size.height / 2,
            maxX: center.x + size.width / 2,
            maxY: center.y + size.height / 2
        )

        self.space = space
        self.extent = extent
        self.center = center
        self.size = size
        self.unclippedRect = rect
        self.normalizedCenter = NormalizedPoint(x: center.x / width, y: center.y / height)
        self.normalizedSize = NormalizedSize(
            width: size.width / width,
            height: size.height / height
        )
        self.normalizedUnclippedRect = NormalizedRect(
            minX: rect.minX / width,
            minY: rect.minY / height,
            maxX: rect.maxX / width,
            maxY: rect.maxY / height
        )
        self.coordinateModel = .continuousEdgeCoordinatesFromUpperLeft
        self.extendsBeyondExtent =
            rect.minX < -tolerance || rect.minY < -tolerance
            || rect.maxX > width + tolerance || rect.maxY > height + tolerance
    }
}

/// A recorded focus centre without a recorded or usable region extent.
public struct FocusLocationGeometry: Sendable, Hashable {
    public let space: GeometrySpace
    public let extent: PixelExtent
    public let center: ContinuousPoint
    public let normalizedCenter: NormalizedPoint
    public let coordinateModel: CoordinateModel

    init?(
        space: GeometrySpace,
        extent: PixelExtent,
        center: ContinuousPoint
    ) {
        let width = Double(extent.width)
        let height = Double(extent.height)
        let tolerance = 1e-9
        guard center.x.isFinite, center.y.isFinite,
            center.x >= -tolerance, center.x <= width + tolerance,
            center.y >= -tolerance, center.y <= height + tolerance
        else { return nil }

        self.space = space
        self.extent = extent
        self.center = center
        self.normalizedCenter = NormalizedPoint(x: center.x / width, y: center.y / height)
        self.coordinateModel = .continuousEdgeCoordinatesFromUpperLeft
    }
}

/// Why no safe geometry is exposed.
public enum FocusGeometryUnavailability: Sendable, Hashable {
    /// The vendor record had no location field.
    case noLocationRecorded
    /// The location record's reference width or height is zero.
    case zeroReferenceExtent
    /// A region was recorded with a zero width or height.
    case zeroRegionExtent
    /// The recorded centre lies outside its own reference extent.
    case centerOutsideReference
    /// Reference tools presented no frame for the recorded availability word.
    case frameNotPresentedByReferenceTools
    /// The availability word is outside the values whose presentation was observed.
    case frameAvailabilityWordUnverified(UInt16)
    /// A binary frame layout whose byte order was not verified for this container.
    case binaryFrameEncodingUnverified
    /// The vendor point has no established reference extent.
    case referenceExtentUnresolved(vendor: CameraVendor)
    /// The vendor semantics needed for pixel geometry are not verified.
    case vendorSemanticsUnverified(vendor: CameraVendor)
    /// The vendor coordinate origin or direction is not verified.
    case originConventionUnverified(vendor: CameraVendor)
    /// The vendor record was inspected and contained no nonempty region.
    case noRegionRecorded(vendor: CameraVendor)
    /// Exif and HEIF orientation representations disagree or have unverified precedence.
    case orientationConflict
}

/// An affine display transform for stored image coordinates.
///
/// The mappings use continuous image-edge coordinates. They describe standard
/// Exif orientation geometry, not a Sony pixel-index convention.
public enum DisplayTransform: String, Sendable, Hashable, CaseIterable {
    case identity
    case mirrorHorizontal
    case rotate180
    case mirrorVertical
    case transpose
    case rotate90Clockwise
    case transverse
    case rotate270Clockwise

    /// Whether the transform exchanges the display width and height.
    public var swapsDimensions: Bool {
        switch self {
        case .identity, .mirrorHorizontal, .rotate180, .mirrorVertical:
            return false
        case .transpose, .rotate90Clockwise, .transverse, .rotate270Clockwise:
            return true
        }
    }

    public func displayExtent(for storedExtent: PixelExtent) -> PixelExtent {
        if swapsDimensions {
            return PixelExtent(width: storedExtent.height, height: storedExtent.width)!
        }
        return storedExtent
    }

    /// Maps a stored centre and region size into the display space.
    public func map(
        center: ContinuousPoint,
        size: ContinuousSize,
        storedExtent: PixelExtent
    ) -> OrientedPlacement {
        let width = Double(storedExtent.width)
        let height = Double(storedExtent.height)
        let mappedCenter: ContinuousPoint
        switch self {
        case .identity:
            mappedCenter = ContinuousPoint(x: center.x, y: center.y)
        case .mirrorHorizontal:
            mappedCenter = ContinuousPoint(x: width - center.x, y: center.y)
        case .rotate180:
            mappedCenter = ContinuousPoint(x: width - center.x, y: height - center.y)
        case .mirrorVertical:
            mappedCenter = ContinuousPoint(x: center.x, y: height - center.y)
        case .transpose:
            mappedCenter = ContinuousPoint(x: center.y, y: center.x)
        case .rotate90Clockwise:
            mappedCenter = ContinuousPoint(x: height - center.y, y: center.x)
        case .transverse:
            mappedCenter = ContinuousPoint(x: height - center.y, y: width - center.x)
        case .rotate270Clockwise:
            mappedCenter = ContinuousPoint(x: center.y, y: width - center.x)
        }

        let mappedSize: ContinuousSize
        if swapsDimensions {
            mappedSize = ContinuousSize(width: size.height, height: size.width)
        } else {
            mappedSize = size
        }

        return OrientedPlacement(
            extent: displayExtent(for: storedExtent),
            center: mappedCenter,
            size: mappedSize
        )
    }
}

/// A centre and region size after applying a display transform.
public struct OrientedPlacement: Sendable, Hashable {
    public let extent: PixelExtent
    public let center: ContinuousPoint
    public let size: ContinuousSize
}

/// The eight standard Exif orientation values.
public enum ExifOrientation: UInt16, Sendable, Hashable, CaseIterable {
    case identity = 1
    case mirrorHorizontal = 2
    case rotate180 = 3
    case mirrorVertical = 4
    case transpose = 5
    case rotate90Clockwise = 6
    case transverse = 7
    case rotate270Clockwise = 8

    public var transform: DisplayTransform {
        switch self {
        case .identity: return .identity
        case .mirrorHorizontal: return .mirrorHorizontal
        case .rotate180: return .rotate180
        case .mirrorVertical: return .mirrorVertical
        case .transpose: return .transpose
        case .rotate90Clockwise: return .rotate90Clockwise
        case .transverse: return .transverse
        case .rotate270Clockwise: return .rotate270Clockwise
        }
    }
}

/// The raw Exif orientation value and its recognized interpretation.
public struct ExifOrientationRecord: Sendable, Hashable {
    public let rawValue: UInt16
    public let orientation: ExifOrientation?

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
        self.orientation = ExifOrientation(rawValue: rawValue)
    }
}

/// A HEIF item rotation payload and its equivalent display transform.
///
/// HEIF stores a counter-clockwise angle in quarter turns. The equivalent
/// clockwise angle is reported for comparison with Exif orientation values.
public struct PrimaryImageRotation: Sendable, Hashable {
    public let rawPayload: UInt8
    /// Clockwise display rotation in degrees, or nil for an unobserved payload.
    public let clockwiseDegrees: Int?
    public let transform: DisplayTransform?

    public init(rawPayload: UInt8) {
        self.rawPayload = rawPayload
        guard rawPayload <= 3 else {
            self.clockwiseDegrees = nil
            self.transform = nil
            return
        }
        let clockwise = (4 - Int(rawPayload)) % 4
        self.clockwiseDegrees = clockwise * 90
        switch clockwise {
        case 0: self.transform = .identity
        case 1: self.transform = .rotate90Clockwise
        case 2: self.transform = .rotate180
        case 3: self.transform = .rotate270Clockwise
        default: self.transform = nil
        }
    }
}

/// Which orientation representation the container supplied.
public enum OrientationResolution: String, Sendable, Hashable {
    case exifOnly
    case primaryImageRotationOnly
    /// Both representations exist. Their precedence is not established by the verified samples.
    case multipleSourcesUnverified
    /// A primary-image transform was present but could not be interpreted safely.
    case unsupportedPrimaryImageTransform
    /// An orientation field exists but its value is outside the published eight values.
    case unrecognized
    case none
}

/// Stored and display orientation facts.
public struct OrientationFacts: Sendable, Hashable {
    public let exif: ExifOrientationRecord?
    public let primaryImageRotation: PrimaryImageRotation?
    public let resolution: OrientationResolution
    public let displayTransform: DisplayTransform?
    public let displayExtent: PixelExtent?
}
