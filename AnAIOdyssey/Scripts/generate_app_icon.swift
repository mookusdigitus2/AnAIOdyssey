// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
#!/usr/bin/env swift
import AppKit

struct IconSpec: Hashable {
    let pixels: Int
    let filename: String
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets.xcassets/AppIcon.appiconset"

let specs: [IconSpec] = [
    IconSpec(pixels: 16, filename: "icon-16.png"),
    IconSpec(pixels: 32, filename: "icon-32.png"),
    IconSpec(pixels: 40, filename: "icon-40.png"),
    IconSpec(pixels: 58, filename: "icon-58.png"),
    IconSpec(pixels: 60, filename: "icon-60.png"),
    IconSpec(pixels: 64, filename: "icon-64.png"),
    IconSpec(pixels: 76, filename: "icon-76.png"),
    IconSpec(pixels: 80, filename: "icon-80.png"),
    IconSpec(pixels: 87, filename: "icon-87.png"),
    IconSpec(pixels: 120, filename: "icon-120.png"),
    IconSpec(pixels: 128, filename: "icon-128.png"),
    IconSpec(pixels: 152, filename: "icon-152.png"),
    IconSpec(pixels: 167, filename: "icon-167.png"),
    IconSpec(pixels: 180, filename: "icon-180.png"),
    IconSpec(pixels: 256, filename: "icon-256.png"),
    IconSpec(pixels: 512, filename: "icon-512.png"),
    IconSpec(pixels: 1024, filename: "icon-1024.png"),
]

func renderIcon(pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(origin: .zero, size: size)
    let cornerRadius = CGFloat(pixels) * 0.22
    let clipPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    clipPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.16, green: 0.46, blue: 0.78, alpha: 1),
        NSColor(red: 0.05, green: 0.24, blue: 0.48, alpha: 1),
    ])!
    gradient.draw(in: bounds, angle: 135)

    let pointSize = CGFloat(pixels) * 0.46
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
    if let symbol = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let symbolSize = symbol.size
        let origin = NSPoint(
            x: (CGFloat(pixels) - symbolSize.width) / 2,
            y: (CGFloat(pixels) - symbolSize.height) / 2 - CGFloat(pixels) * 0.02
        )
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate_app_icon", code: 1)
    }
    try data.write(to: url)
}

let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for spec in specs {
    let image = renderIcon(pixels: spec.pixels)
    try writePNG(image, to: outputURL.appendingPathComponent(spec.filename))
    fputs("Wrote \(spec.filename)\n", stderr)
}
