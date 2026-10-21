// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageWidget",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageWidget", targets: ["CodexUsageWidget"]),
        .library(name: "CodexBarReleaseDetection", targets: ["CodexBarReleaseDetection"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageWidget",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .target(
            name: "CodexBarReleaseDetection"
        ),
        .testTarget(
            name: "CodexUsageWidgetTests",
            dependencies: ["CodexUsageWidget", "CodexBarReleaseDetection"]
        ),
        .testTarget(
            name: "CodexBarReleaseDetectionTests",
            dependencies: ["CodexBarReleaseDetection"],
            exclude: ["Fixtures"]
        )
    ]
)
