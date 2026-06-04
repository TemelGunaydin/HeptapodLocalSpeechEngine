// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HeptapodLocalSpeechEngine",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HeptapodLocalSpeechEngine",
            targets: ["HeptapodLocalSpeechEngine"]
        )
    ],
    targets: [
        .target(
            name: "HeptapodLocalSpeechEngine"
        ),
        .testTarget(
            name: "HeptapodLocalSpeechEngineTests",
            dependencies: ["HeptapodLocalSpeechEngine"]
        )
    ]
)
