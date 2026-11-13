import Foundation

/// Mutable parse state that becomes an immutable report.
final class ExtractionBuilder {
    var container: ContainerDescription
    var camera: CameraIdentity?
    var imageExtent: PixelExtent?
    var exifOrientation: ExifOrientationRecord?
    var primaryImageRotation: PrimaryImageRotation?
    var primaryImageTransformUnsupported = false
    var focus: RecordedFocus?
    var issues: [MetadataIssue] = []
    var uncertainties: [Uncertainty] = []

    var focusPathMalformed = false
    var focusPathUnsupported = false
    var focusPathSupported = false

    init(container: ContainerDescription) {
        self.container = container
    }

    func addIssue(_ kind: MetadataIssue.Kind, context: String, detail: String? = nil) {
        issues.append(MetadataIssue(kind: kind, context: context, detail: detail))
    }

    func addIssue(failure: ParseFailure, context: String) {
        issues.append(MetadataIssue(failure: failure, context: context))
    }

    func addUncertainty(_ uncertainty: Uncertainty) {
        guard !uncertainties.contains(uncertainty) else { return }
        uncertainties.append(uncertainty)
    }

    func addUncertainties(_ values: [Uncertainty]) {
        for value in values {
            addUncertainty(value)
        }
    }

    func addIssues(_ values: [MetadataIssue]) {
        issues.append(contentsOf: values)
    }

    func makeReport() -> FocusMetadataReport {
        let orientation = resolveOrientation()
        let displayGeometry = resolveDisplayGeometry(orientation: orientation)
        let status = determineStatus()
        return FocusMetadataReport(
            status: status,
            container: container,
            camera: camera,
            imageExtent: imageExtent,
            orientation: orientation,
            focus: focus,
            displayGeometry: displayGeometry,
            issues: issues,
            uncertainties: uncertainties
        )
    }

    private func resolveOrientation() -> OrientationFacts {
        let exif = exifOrientation
        let rotation = primaryImageRotation

        if primaryImageTransformUnsupported {
            addUncertainty(.primaryImageTransformUnsupported)
            if let exif, exif.orientation == nil {
                addIssue(
                    .unrecognizedOrientation,
                    context: "Exif tag 0x0112",
                    detail: "Raw value \(exif.rawValue) is outside the eight standard values."
                )
            }
            if let rotation, rotation.transform == nil {
                addIssue(
                    .unrecognizedOrientation,
                    context: "HEIF primary-image irot",
                    detail: "Raw payload \(rotation.rawPayload) is outside the observed 0...3 range."
                )
            }
            return OrientationFacts(
                exif: exif,
                primaryImageRotation: rotation,
                resolution: .unsupportedPrimaryImageTransform,
                displayTransform: nil,
                displayExtent: nil
            )
        }

        if let exif, let rotation {
            addUncertainty(.orientationPrecedenceUnestablished)
            if exif.orientation == nil || rotation.transform == nil {
                addIssue(
                    .unrecognizedOrientation,
                    context: "Exif and HEIF orientation",
                    detail: "At least one orientation representation is outside the observed values."
                )
            } else if exif.orientation?.transform != rotation.transform {
                addIssue(
                    .conflictingOrientations,
                    context: "Exif orientation and HEIF primary-image irot",
                    detail: "Precedence is not established by the verified samples."
                )
            }
            return OrientationFacts(
                exif: exif,
                primaryImageRotation: rotation,
                resolution: .multipleSourcesUnverified,
                displayTransform: nil,
                displayExtent: nil
            )
        }

        if let exif {
            guard let parsed = exif.orientation else {
                addIssue(
                    .unrecognizedOrientation,
                    context: "Exif tag 0x0112",
                    detail: "Raw value \(exif.rawValue) is outside the eight standard values."
                )
                addUncertainty(.displayOrientationUnknown)
                return OrientationFacts(
                    exif: exif,
                    primaryImageRotation: nil,
                    resolution: .unrecognized,
                    displayTransform: nil,
                    displayExtent: nil
                )
            }
            let transform = parsed.transform
            return OrientationFacts(
                exif: exif,
                primaryImageRotation: nil,
                resolution: .exifOnly,
                displayTransform: transform,
                displayExtent: imageExtent.map(transform.displayExtent)
            )
        }

        if let rotation {
            guard let transform = rotation.transform else {
                addIssue(
                    .unrecognizedOrientation,
                    context: "HEIF primary-image irot",
                    detail: "Raw payload \(rotation.rawPayload) is outside the observed 0...3 range."
                )
                addUncertainty(.displayOrientationUnknown)
                return OrientationFacts(
                    exif: nil,
                    primaryImageRotation: rotation,
                    resolution: .unrecognized,
                    displayTransform: nil,
                    displayExtent: nil
                )
            }
            return OrientationFacts(
                exif: nil,
                primaryImageRotation: rotation,
                resolution: .primaryImageRotationOnly,
                displayTransform: transform,
                displayExtent: imageExtent.map(transform.displayExtent)
            )
        }

        addUncertainty(.displayOrientationUnknown)
        return OrientationFacts(
            exif: nil,
            primaryImageRotation: nil,
            resolution: .none,
            displayTransform: nil,
            displayExtent: nil
        )
    }

    private func resolveDisplayGeometry(orientation: OrientationFacts) -> FocusGeometry? {
        guard let transform = orientation.displayTransform, let focus else {
            return nil
        }
        switch focus.geometry {
        case .region(let region):
            let placed = transform.map(
                center: region.center,
                size: region.size,
                storedExtent: region.extent
            )
            guard
                let display = FocusRegionGeometry(
                    space: .display,
                    extent: placed.extent,
                    center: placed.center,
                    size: placed.size
                )
            else {
                addIssue(
                    .unverifiedGeometry,
                    context: "Display geometry",
                    detail: "The transformed centre did not remain inside the display extent."
                )
                return nil
            }
            addUncertainty(.continuousCoordinateApproximation)
            return .region(display)
        case .location(let location):
            let placed = transform.map(
                center: location.center,
                size: ContinuousSize(width: 1, height: 1),
                storedExtent: location.extent
            )
            guard
                let display = FocusLocationGeometry(
                    space: .display,
                    extent: placed.extent,
                    center: placed.center
                )
            else {
                addIssue(
                    .unverifiedGeometry,
                    context: "Display geometry",
                    detail: "The transformed centre did not remain inside the display extent."
                )
                return nil
            }
            addUncertainty(.continuousCoordinateApproximation)
            return .location(display)
        case .unavailable:
            return nil
        }
    }

    private func determineStatus() -> ExtractionStatus {
        if focusPathMalformed {
            return .malformed
        }
        if let focus {
            return focus.sony != nil ? .verifiedSonyFocusMetadata : .rawVendorObservation
        }
        if focusPathUnsupported {
            return .unsupported
        }
        if focusPathSupported {
            return .focusMetadataMissing
        }
        return .unsupported
    }
}
