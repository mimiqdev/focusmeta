import Foundation
import Testing

@testable import CameraFocusMetadata

@Suite("Standard orientation and boundary geometry")
struct OrientationGeometryTests {
    @Test("All eight Exif orientation examples")
    func exifOrientationExamples() throws {
        for vector in HandoffVectors.orientations {
            let orientation = try #require(ExifOrientation(rawValue: vector.orientation))
            let storedExtent = try #require(
                PixelExtent(width: vector.storedExtent.0, height: vector.storedExtent.1)
            )
            let displayExtent = try #require(
                PixelExtent(width: vector.displayExtent.0, height: vector.displayExtent.1)
            )
            let transform = orientation.transform
            #expect(
                transform.displayExtent(for: storedExtent) == displayExtent,
                "\(vector.id) display extent"
            )
            let placed = transform.map(
                center: ContinuousPoint(x: vector.storedCenter.0, y: vector.storedCenter.1),
                size: ContinuousSize(width: vector.storedSize.0, height: vector.storedSize.1),
                storedExtent: storedExtent
            )
            #expect(placed.extent == displayExtent, "\(vector.id) placement extent")
            #expect(placed.center.x == vector.displayCenter.0, "\(vector.id) centre x")
            #expect(placed.center.y == vector.displayCenter.1, "\(vector.id) centre y")
            #expect(placed.size.width == vector.displaySize.0, "\(vector.id) size width")
            #expect(placed.size.height == vector.displaySize.1, "\(vector.id) size height")
        }
    }

    @Test("Orientations five through eight exchange dimensions")
    func dimensionSwap() {
        for orientation in ExifOrientation.allCases {
            let expectsSwap = orientation.rawValue >= 5
            #expect(orientation.transform.swapsDimensions == expectsSwap)
        }
    }

    @Test("Boundary geometry uses continuous, unclipped coordinates")
    func boundaryGeometry() throws {
        for vector in HandoffVectors.boundaries {
            let extent = PixelExtent(
                width: vector.referenceExtent.0,
                height: vector.referenceExtent.1
            )
            switch vector.id {
            case "zero-reference":
                #expect(extent == nil)
                #expect(vector.unclippedRect == nil)
                continue
            case "center-outside", "zero-size":
                #expect(vector.unclippedRect == nil)
                let geometry = extent.flatMap {
                    FocusRegionGeometry(
                        space: .storedReference,
                        extent: $0,
                        center: ContinuousPoint(
                            x: Double(vector.center.0),
                            y: Double(vector.center.1)
                        ),
                        size: ContinuousSize(
                            width: Double(vector.size.0),
                            height: Double(vector.size.1)
                        )
                    )
                }
                #expect(geometry == nil, "\(vector.id) should not produce safe geometry")
                continue
            default:
                break
            }

            let safeExtent = try #require(extent)
            let geometry = try #require(
                FocusRegionGeometry(
                    space: .storedReference,
                    extent: safeExtent,
                    center: ContinuousPoint(
                        x: Double(vector.center.0),
                        y: Double(vector.center.1)
                    ),
                    size: ContinuousSize(
                        width: Double(vector.size.0),
                        height: Double(vector.size.1)
                    )
                ),
                "\(vector.id) should produce geometry"
            )
            let rect = try #require(vector.unclippedRect)
            #expect(geometry.unclippedRect.minX == rect[0], "\(vector.id) minX")
            #expect(geometry.unclippedRect.minY == rect[1], "\(vector.id) minY")
            #expect(geometry.unclippedRect.maxX == rect[2], "\(vector.id) maxX")
            #expect(geometry.unclippedRect.maxY == rect[3], "\(vector.id) maxY")
            #expect(
                geometry.normalizedCenter.x == Double(vector.center.0) / Double(safeExtent.width)
            )
            #expect(
                geometry.normalizedCenter.y == Double(vector.center.1) / Double(safeExtent.height)
            )

            switch vector.id {
            case "upper-left-edge", "lower-right-edge", "oversized-region":
                #expect(geometry.extendsBeyondExtent, "\(vector.id) should extend")
            case "whole-image", "odd-size":
                #expect(!geometry.extendsBeyondExtent, "\(vector.id) should fit")
            default:
                break
            }
        }
    }

    @Test("Normalized geometry is derived from the recorded reference extent")
    func normalizedGeometry() throws {
        let extent = try #require(PixelExtent(width: 80, height: 60))
        let geometry = try #require(
            FocusRegionGeometry(
                space: .storedReference,
                extent: extent,
                center: ContinuousPoint(x: 17, y: 31),
                size: ContinuousSize(width: 10, height: 6)
            )
        )
        #expect(geometry.normalizedCenter == NormalizedPoint(x: 17.0 / 80.0, y: 31.0 / 60.0))
        #expect(geometry.normalizedSize == NormalizedSize(width: 0.125, height: 0.1))
        #expect(geometry.normalizedUnclippedRect.minX == 12.0 / 80.0)
        #expect(geometry.normalizedUnclippedRect.maxY == 34.0 / 60.0)
    }
}
