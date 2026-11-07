// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import PackageDescription

let package = Package(
    name: "AnAIOdysseyCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AnAIOdysseyCore", targets: ["AnAIOdysseyCore"]),
    ],
    dependencies: [
        .package(path: "../../../AIConnect/AIConnect"),
    ],
    targets: [
        .target(
            name: "AnAIOdysseyCore",
            dependencies: [
                .product(name: "AIConnect", package: "AIConnect"),
            ],
            linkerSettings: [
                .linkedFramework("Photos", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("ImageIO", .when(platforms: [.iOS, .macOS])),
            ]
        ),
    ]
)
