// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraFocusMetadata",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CameraFocusMetadata", targets: ["CameraFocusMetadata"])
    ],
    targets: [
        .target(
            name: "CameraFocusMetadata",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CameraFocusMetadataTests",
            dependencies: ["CameraFocusMetadata"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
