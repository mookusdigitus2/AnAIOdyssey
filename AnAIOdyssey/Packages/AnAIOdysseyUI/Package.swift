// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import PackageDescription

let package = Package(
    name: "AnAIOdysseyUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AnAIOdysseyUI", targets: ["AnAIOdysseyUI"]),
    ],
    dependencies: [
        .package(path: "../AnAIOdysseyCore"),
        .package(path: "../AnAIOdysseyAI"),
        .package(path: "../../../AIConnect/AIModelOptions"),
        .package(path: "../AnAIOdysseyMail"),
        .package(path: "../../../AIConnect/AIConnect"),
    ],
    targets: [
        .target(
            name: "AnAIOdysseyUI",
            dependencies: [
                "AnAIOdysseyCore",
                "AnAIOdysseyAI",
                "AnAIOdysseyMail",
                .product(name: "AIConnect", package: "AIConnect"),
                .product(name: "AIConnectUI", package: "AIConnect"),
                .product(name: "AIModelOptions", package: "AIModelOptions"),
            ]
        ),
    ]
)
