// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HeptapodLocalSpeechEngine",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "HeptapodLocalSpeechEngine",
            targets: ["HeptapodLocalSpeechEngine"]
        ),
        .library(
            name: "HeptapodSpeechSwiftAdapters",
            targets: ["HeptapodSpeechSwiftAdapters"]
        ),
        .executable(
            name: "HeptapodLiveSpeechDemo",
            targets: ["HeptapodLiveSpeechDemo"]
        ),
        .executable(
            name: "HeptapodRealSpeechDemo",
            targets: ["HeptapodRealSpeechDemo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.9")
    ],
    targets: [
        .target(
            name: "HeptapodLocalSpeechEngine"
        ),
        .target(
            name: "HeptapodSpeechSwiftAdapters",
            dependencies: [
                "HeptapodLocalSpeechEngine",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MADLADTranslation", package: "speech-swift"),
                .product(name: "KokoroTTS", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift")
            ]
        ),
        .executableTarget(
            name: "HeptapodLiveSpeechDemo",
            dependencies: [
                "HeptapodLocalSpeechEngine",
                "HeptapodSpeechSwiftAdapters"
            ]
        ),
        .executableTarget(
            name: "HeptapodRealSpeechDemo",
            dependencies: [
                "HeptapodLocalSpeechEngine",
                "HeptapodSpeechSwiftAdapters"
            ]
        ),
        .testTarget(
            name: "HeptapodLocalSpeechEngineTests",
            dependencies: [
                "HeptapodLocalSpeechEngine",
                "HeptapodSpeechSwiftAdapters"
            ]
        )
    ]
)
