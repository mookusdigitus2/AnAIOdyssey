// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class ImageFileCodecTests: XCTestCase {
    /// 1×1 PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testSniffsPNGAndJPEGMagicBytes() {
        XCTAssertEqual(ImageFileCodec.sniff(png), .png)
        XCTAssertEqual(ImageFileCodec.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 12)), .jpeg)
        XCTAssertNil(ImageFileCodec.sniff(Data("not-an-image".utf8)))
    }

    func testPreferredExtensionPrefersSniffedBytesOverSuggestedName() {
        XCTAssertEqual(
            ImageFileCodec.preferredFileExtension(for: png, suggestedFilename: "generated.jpg"),
            "png"
        )
        XCTAssertEqual(
            ImageFileCodec.preferredFileExtension(for: Data("x".utf8), suggestedFilename: "photo.heic"),
            "heic"
        )
        XCTAssertEqual(
            ImageFileCodec.preferredFileExtension(for: Data("x".utf8), suggestedFilename: "no-ext"),
            "png"
        )
    }

    func testGalleryStorageKeepsPNGAndConvertsUnknownImage() throws {
        let storedPNG = try ImageFileCodec.galleryStorageData(from: png)
        XCTAssertEqual(storedPNG.fileExtension, "png")
        XCTAssertEqual(storedPNG.data, png)

        let roundTrip = try ImageFileCodec.pngData(from: png, square: true)
        XCTAssertEqual(ImageFileCodec.sniff(roundTrip), .png)
        XCTAssertFalse(roundTrip.isEmpty)
    }
}
