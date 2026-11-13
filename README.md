# CameraFocusMetadata

A small, read-only Swift library for recorded camera focus metadata. It parses
metadata containers directly with bounded reads; it does not decode images,
detect faces, score focus, or write metadata.

The first verified release targets the Sony ILCE-1M2 AF-C ARW/HIF scope
documented in the sanitized format handoff. Other vendors expose bounded raw
observations only, with their pixel geometry explicitly unverified.

## Requirements

- Swift 6 with complete strict concurrency
- iOS 18 or later
- macOS 15 or later (for tests and desktop use)
- Foundation and Swift standard library only; no third-party dependencies
  and no runtime executables

## Usage

```swift
import CameraFocusMetadata

let report = try FocusMetadataReader().read(fileAt: fileURL)

print(report.status)                         // e.g. .verifiedSonyFocusMetadata
print(report.camera?.model ?? "unknown")     // "ILCE-1M2"
print(report.imageExtent as Any)             // 8640x5760, before display rotation

if case .region(let region)? = report.focus?.geometry {
    print(region.center)                     // continuous recorded coordinates
    print(region.normalizedCenter)           // fractions of the reference extent
    print(region.unclippedRect)
}

if case .region(let displayed)? = report.displayGeometry {
    print(displayed.extent)                  // 5760x8640 for the portrait examples
    print(displayed.center)
}

for uncertainty in report.uncertainties {
    print(uncertainty.rawValue)
}
```

Read in-memory metadata-only bytes with `read(data:)`. Both entry points return
a `FocusMetadataReport` unless the input itself cannot be opened or identified.
Structural problems inside a recognized container are reported through
`status` and `issues`.

## What the result means

`FocusMetadataReport` contains:

| Field | Meaning |
| --- | --- |
| `status` | Verified Sony metadata, raw vendor observation, missing, unsupported, or malformed |
| `container` | Container kind, TIFF byte order, MakerNote flavor, and entry point |
| `camera` | Recorded make, model, and software string |
| `imageExtent` | Recorded stored image extent before display rotation |
| `orientation` | Exif and/or HEIF primary-image rotation facts |
| `focus` | Recorded focus fields and safe stored-space geometry |
| `displayGeometry` | The same geometry transformed into display space, when orientation is unambiguous |
| `issues` | Recoverable structural or support problems |
| `uncertainties` | Limits that apply to the reported values |

Focus geometry is one of:

- `.region` — a center and region size backed by recorded dimensions
- `.location` — a recorded center with no recorded or usable region extent
- `.unavailable(reason)` — no safe geometry, with an explicit reason

There is no default AF rectangle. Missing, zero, out-of-range, malformed, or
unknown-availability data never becomes a valid centered region. A centered
value is tagged with `centerMayBeCameraFallback` because the reference material
documents a camera fallback for an unrecordable focus location.

The Sony location field is treated as a playback-zoom hint. It is not confirmed
active autofocus, successful focus acquisition, subject tracking, or image
sharpness. These limits are always attached as uncertainties when a Sony hint
is present.

## Verified Sony scope

The verified facts cover four ILCE-1M2 AF-C captures, each recorded as an ARW
and an HIF. The library reads:

| Source | Field | Treatment |
| --- | --- | --- |
| IFD0 | `0x010f`, `0x0110`, `0x0131` | Make, model, recorded software |
| Exif | `0xa002`, `0xa003` | Stored image extent |
| IFD0 | `0x0112` | Exif orientation 1...8; other values are unrecognized |
| HEIF | primary `ispe` | Stored primary-image extent |
| HEIF | primary `irot` | Rotation payload 0...3, associated through `ipma` |
| Sony | `0x201b` | Raw mode code; code 3 has the reference-tool label AF-C |
| Sony | `0x201c` | Raw configured-area code only; no invented area meaning |
| Sony | `0x2027` | Four words: reference width, reference height, x, y |
| Sony | `0x2037` | Six raw bytes; three little-endian words in real captures |
| Sony | `0x204a` | Second four-word location record, retained and compared |
| Sony | `0x2020` | Raw legacy point-use bytes |

The HEIF Exif item must have an explicit `cdsc` association exclusively to the
declared primary item. An item linked elsewhere, an absent association, or an
ambiguous association is reported as unsupported instead of being attached to
the primary image.

The frame record's third word is an availability-related word of unverified bit
meaning. Reference tools displayed no frame for word 0 and displayed the frame
for 1, 256, 257, and 65535. The library uses those observations only to decide
whether a region can be presented; it does not call the word a focus-success
flag. Other word values produce `.unavailable(.frameAvailabilityWordUnverified)`.

Real Sony frame records were verified in little-endian containers only. For a
big-endian container, the raw frame bytes are preserved but no frame is decoded,
and geometry is limited to the recorded center where valid.

An availability word of 0 produces `.unavailable(.frameNotPresentedByReferenceTools)`;
zero frame dimensions produce `.unavailable(.zeroRegionExtent)`. Zero reference
dimensions, an out-of-range center, absent tags, and conflicting location
records all have distinct outcomes.

## Coordinates and orientation

Coordinates are continuous image-edge coordinates from the upper-left. The
library does not assert a camera pixel-center convention, zero- versus one-based
indexing, endpoint rounding, or sensor-site correspondence. Normalized values
are fractions of the record's own reference extent.

All eight standard Exif orientation examples are implemented. Exif values 5-8
exchange display width and height. HEIF `irot` payload 1 is equivalent to 270°
clockwise, matching Exif orientation 8 in the verified pairs.

If both an Exif orientation and a HEIF primary-image rotation exist, the library
keeps both raw records, reports `.multipleSourcesUnverified`, sets no display
transform, and does not claim precedence. An associated `imir` or `clap`, more
than one associated `irot`, an unreadable transform payload, or an invalid
primary transform association reports `.unsupportedPrimaryImageTransform` and
suppresses display transform/geometry while retaining the other stored
observations. Display geometry is produced only with one unambiguous orientation
source. A recorded focus tuple is never assumed to be already rotated.

## Other manufacturers

Other entry points are deliberately narrow:

| Sample path | Library behavior |
| --- | --- |
| Canon CR3 `moov` UUID → `CMT3` | Raw `0x0026` AF block prefix/final words; geometry unverified |
| Nikon MakerNote `0x00b7` | Raw AF block and recorded mode string; geometry unverified |
| Fujifilm RAF embedded JPEG | Raw `0x1021`, `0x1023`, `0x102d`, `0x1301`; reference extent unresolved |
| Panasonic RW2 embedded JPEG | Raw `0x004d` rationals and related fields; origin unverified |
| Olympus ORF CameraSettings | Raw `0x0301`–`0x0305`; empty storage reported as no region |
| Pentax DNG `0xc634` payload | Raw `0x000d`, `0x000e`, `0x021f`; geometry unverified |

No vendor beyond the Sony scope receives a usable pixel region. Raw records use
the field shapes that were actually observed; this is not a general vendor
support claim.

## Bounded I/O and privacy

- File reads are range-based; a full-resolution original is never loaded just
  to read metadata.
- Every offset, count, type width, and multiplication is validated before use.
- Directory depth, entry counts, box counts, MakerNote size, Exif item size, and
  total read bytes are bounded. Directory cycles are rejected.
- A MakerNote directory table is bounded by the declared MakerNote extent even
  when later bytes exist in the file. MakerNote out-of-line values retain their
  verified enclosing-TIFF-relative offsets and bounds.
- HIF Exif values are bounded by the Exif item extent. Out-of-line TIFF values
  are bounded by the enclosing TIFF or MakerNote region.
- The report contains no file paths, serial numbers, GPS data, timestamps, or
  other identifying capture metadata.
- Private originals are opened read-only and are never modified.

## Testing

Synthetic tests use independently constructed metadata-only TIFF/HEIF bytes and
the handoff's synthetic vectors. They cover the recorded Sony words, all eight
orientation examples, boundary geometry, malformed shapes, truncation, overflow,
cycles, unsupported HEIF layouts, big-endian frame handling, and explicit
missing/unsupported outcomes.

Run them with:

```sh
swift test
```

Real-sample integration is opt-in and uses only opaque sample names. Point the
environment variable at a directory containing `S01.ARW`/`S01.HIF` through
`S04.ARW`/`S04.HIF`:

```sh
CAMERA_FOCUS_METADATA_SAMPLES_DIR=/path/to/authorized/samples swift test
```

Without that setting, the integration tests are disabled and the synthetic
suite still runs. Sample files are not part of this repository.

## Input boundary

This implementation was written from a sanitized format-facts handoff,
published TIFF/Exif/HEIF facts, and the owner-authorized local samples. It did
not use upstream parser implementations, upstream tool source, private research
notes or scripts, extracted tag databases, or the Clove application's existing
metadata code. Reference-tool behavior appears only as a labeled observation,
not as an implementation dependency.

That stated separation is a process boundary for this work. It does not
establish or guarantee legal clean-room status.

## Unresolved questions

The verified evidence does not settle, among other things:

- physical AF accuracy or focus success
- the camera's pixel indexing and odd-size endpoint rounding
- the bit-level meaning of the frame availability word
- a true central focus versus the camera's centered fallback
- AF-S, MF, DMF, and failed-focus behavior on the ILCE-1M2
- real big-endian Sony frame encoding
- replacement or precedence semantics for `0x204a`
- Exif/HEIF orientation conflicts, mirroring, and cropped derived images
- other Sony models, JPEGs, reduced-resolution modes, and crop modes
- usable pixel geometry for every non-Sony vendor

These are reported as uncertainties or explicit unsupported outcomes rather than
filled in with invented defaults.

## License

Licensed under the [MIT License](LICENSE).
