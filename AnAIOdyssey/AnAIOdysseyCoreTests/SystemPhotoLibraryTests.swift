// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class SystemPhotoLibraryTests: XCTestCase {
    func testPreparedImageDataRejectsNonImages() {
        XCTAssertThrowsError(try SystemPhotoLibrary.preparedImageData(Data("not-an-image".utf8))) { error in
            XCTAssertEqual(error as? SystemPhotoLibrary.LibraryError, .invalidImage)
        }
    }

    func testPreparedImageDataKeepsPNG() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let prepared = try SystemPhotoLibrary.preparedImageData(png)
        XCTAssertEqual(prepared.fileExtension, "png")
        XCTAssertFalse(prepared.data.isEmpty)
    }

    func testGeneratedAlbumName() {
        XCTAssertEqual(GeneratedImagesAlbum.name, "AI Generated")
    }

    func testAddOnlyMeansWriteWithoutRead() {
        XCTAssertFalse(SystemPhotoLibrary.canReadPhotos && SystemPhotoLibrary.isAddOnly)
        if SystemPhotoLibrary.isAddOnly {
            XCTAssertTrue(SystemPhotoLibrary.canAddPhotos)
            XCTAssertFalse(SystemPhotoLibrary.canReadPhotos)
        }
    }

    func testAccessDeniedMessagePointsAtSettings() {
        XCTAssertEqual(
            SystemPhotoLibrary.LibraryError.accessDenied.errorDescription,
            "Photos access is turned off. Enable it in Settings to save images to your Photos library."
        )
    }
}
