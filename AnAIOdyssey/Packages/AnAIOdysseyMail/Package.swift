// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import PackageDescription

let package = Package(
    name: "AnAIOdysseyMail",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AnAIOdysseyMail", targets: ["AnAIOdysseyMail"]),
    ],
    dependencies: [
        .package(path: "../AnAIOdysseyCore"),
        .package(path: "../AnAIOdysseyAI"),
    ],
    targets: [
        .target(
            name: "AnAIOdysseyMail",
            dependencies: ["AnAIOdysseyCore", "AnAIOdysseyAI"]
        ),
    ]
)
