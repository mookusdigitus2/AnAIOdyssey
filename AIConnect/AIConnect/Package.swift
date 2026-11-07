// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
import PackageDescription

/// Shared connectivity suite: reaching AI models (Apple's on-device model, local
/// downloads, LM Studio, OpenAI-compatible and other remote connections),
/// and their settings. No app prompts, agents or features live here. (In the
/// private monorepo this package also carries the `AIConnectVoice` voice engine;
/// for the public release that target lives in a separate folder pending a
/// licensing decision.)
let package = Package(
    name: "AIConnect",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AIConnect", targets: ["AIConnect"]),
        .library(name: "AIConnectUI", targets: ["AIConnectUI"]),
    ],
    dependencies: [
        .package(path: "../AIModelOptions"),
    ],
    targets: [
        .target(
            name: "AIConnect",
            dependencies: [
                .product(name: "AIModelOptions", package: "AIModelOptions"),
            ]
        ),
        .target(
            name: "AIConnectUI",
            dependencies: ["AIConnect"]
        ),
        .testTarget(
            name: "AIConnectTests",
            dependencies: ["AIConnect"]
        ),
    ]
)
