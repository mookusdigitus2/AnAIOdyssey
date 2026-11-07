// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
import PackageDescription

/// Voice engine (duplex audio, speech input, barge-in, TTS providers) split
/// out of the AIConnect package for the public release. Module name, types and
/// API are unchanged from the private monorepo's `AIConnectVoice` target.
let package = Package(
    name: "AIConnectVoice",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AIConnectVoice", targets: ["AIConnectVoice"]),
    ],
    dependencies: [
        .package(path: "../AIConnect/AIConnect"),
        .package(path: "../AIConnect/AIModelOptions"),
    ],
    targets: [
        .target(
            name: "AIConnectVoice",
            dependencies: [
                .product(name: "AIConnect", package: "AIConnect"),
                .product(name: "AIModelOptions", package: "AIModelOptions"),
            ],
            linkerSettings: [
                .linkedFramework("Speech", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "AIConnectVoiceTests",
            dependencies: [
                "AIConnectVoice",
                .product(name: "AIConnect", package: "AIConnect"),
                .product(name: "AIModelOptions", package: "AIModelOptions"),
            ]
        ),
    ]
)
