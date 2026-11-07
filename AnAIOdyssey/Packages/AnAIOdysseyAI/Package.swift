// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import PackageDescription

let package = Package(
    name: "AnAIOdysseyAI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AnAIOdysseyAI", targets: ["AnAIOdysseyAI"]),
        .library(name: "AnAIOdysseyMLX", targets: ["AnAIOdysseyMLX"]),
    ],
    dependencies: [
        .package(path: "../AnAIOdysseyCore"),
        .package(path: "../../../AIConnect/AIModelOptions"),
        .package(path: "../../../AIConnect/AIConnect"),
        .package(path: "../../../AIConnectVoice"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.21.2"),
    ],
    targets: [
        .target(
            name: "AnAIOdysseyAI",
            dependencies: [
                "AnAIOdysseyCore",
                .product(name: "AIModelOptions", package: "AIModelOptions"),
                .product(name: "AIConnect", package: "AIConnect"),
                .product(name: "AIConnectVoice", package: "AIConnectVoice"),
            ],
            linkerSettings: [
                .linkedFramework("Speech", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .target(
            name: "AnAIOdysseyMLX",
            dependencies: [
                "AnAIOdysseyAI",
                "AnAIOdysseyCore",
                .product(name: "AIModelOptions", package: "AIModelOptions"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            ]
        ),
    ]
)
