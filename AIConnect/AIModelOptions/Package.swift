// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "AIModelOptions",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "AIModelOptions", targets: ["AIModelOptions"]),
    ],
    targets: [
        .target(name: "AIModelOptions"),
        .testTarget(
            name: "AIModelOptionsTests",
            dependencies: ["AIModelOptions"]
        ),
    ]
)
