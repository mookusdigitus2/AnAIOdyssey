// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class PhotosGalleryImporterTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private var galleryDirectory: URL!
    private var gallery: SwiftDataGalleryRepository!

    override func setUpWithError() throws {
        galleryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
        let context = try TestModelContainer.makeContext()
        gallery = SwiftDataGalleryRepository(context: context, galleryDirectory: galleryDirectory)
    }

    override func tearDownWithError() throws {
        if let galleryDirectory {
            try? FileManager.default.removeItem(at: galleryDirectory)
        }
        gallery = nil
        galleryDirectory = nil
    }

    func testChecksumIsStable() {
        XCTAssertEqual(PhotosGalleryImporter.checksum(for: png), PhotosGalleryImporter.checksum(for: png))
        XCTAssertNotEqual(PhotosGalleryImporter.checksum(for: png), PhotosGalleryImporter.checksum(for: Data("x".utf8)))
    }

    func testImportCreatesAIGeneratedAlbum() throws {
        let imported = try PhotosGalleryImporter.importItems(
            [PhotosGalleryImportItem(
                localIdentifier: "asset-1",
                albumTitle: GeneratedImagesAlbum.name,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                data: png
            )],
            into: gallery
        )
        XCTAssertEqual(imported, 1)
        let albums = try gallery.listAlbums()
        XCTAssertEqual(albums.map(\.name), [GeneratedImagesAlbum.name])
        let images = try gallery.listImages(albumID: albums[0].id)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].photosAssetIdentifier, "asset-1")
        XCTAssertEqual(images[0].contentChecksum, PhotosGalleryImporter.checksum(for: png))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gallery.imageFileURL(for: images[0]).path))
    }

    func testImportDoesNotDuplicateTheSamePhoto() throws {
        let item = PhotosGalleryImportItem(
            localIdentifier: "asset-1",
            albumTitle: GeneratedImagesAlbum.name,
            createdAt: Date(),
            data: png
        )
        XCTAssertEqual(try PhotosGalleryImporter.importItems([item], into: gallery), 1)
        XCTAssertEqual(try PhotosGalleryImporter.importItems([item], into: gallery), 0)
        let album = try gallery.listAlbums()[0]
        XCTAssertEqual(try gallery.listImages(albumID: album.id).count, 1)
    }

    func testImportFillsCloudKitRecordWithMissingFile() throws {
        let album = try GeneratedImagesAlbum.findOrCreate(in: gallery)
        let image = try gallery.importImage(
            albumID: album.id,
            data: png,
            suggestedFilename: "missing.png",
            caption: "sunset over the lake"
        )
        try FileManager.default.removeItem(at: gallery.imageFileURL(for: image))
        image.contentChecksum = nil
        image.photosAssetIdentifier = nil
        try gallery.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: gallery.imageFileURL(for: image).path))

        let imported = try PhotosGalleryImporter.importItems(
            [PhotosGalleryImportItem(
                localIdentifier: "iphone-asset",
                albumTitle: GeneratedImagesAlbum.name,
                createdAt: image.createdAt,
                data: png
            )],
            into: gallery
        )
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(try gallery.listImages(albumID: album.id).count, 1)
        let filled = try gallery.listImages(albumID: album.id)[0]
        XCTAssertEqual(filled.id, image.id)
        XCTAssertEqual(filled.caption, "sunset over the lake")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gallery.imageFileURL(for: filled).path))
    }

    func testImportImageRecordsChecksum() throws {
        let album = try gallery.createAlbum(name: "Trip", description: nil)
        let image = try gallery.importImage(
            albumID: album.id,
            data: png,
            suggestedFilename: "photo.png",
            caption: nil
        )
        XCTAssertEqual(image.contentChecksum, PhotosGalleryImporter.checksum(for: png))
    }
}
