// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Photos

/// Pulls images from the system Photos library into the in-app gallery.
///
/// Generated images are mirrored into Photos (and sync across devices via
/// iCloud Photos). Gallery metadata/files do not follow that path, so the
/// iPhone app has to read the shared “AI Generated” album (and any in-app
/// album that also exists in Photos) to show work created on another device.
@MainActor
public enum PhotosGallerySync {
    private static var isRunning = false

    /// Downloads Photos assets into `gallery`. Returns how many images were added
    /// or repaired. No-ops when Photos access is add-only or denied.
    @discardableResult
    public static func run(gallery: any GalleryRepositoryProtocol) async -> Int {
        guard !isRunning else { return 0 }
        guard !shouldSkip else { return 0 }
        isRunning = true
        defer { isRunning = false }

        if !SystemPhotoLibrary.canReadPhotos {
            _ = await SystemPhotoLibrary.requestAccess()
        }
        guard SystemPhotoLibrary.canReadPhotos else { return 0 }

        var titles = Set<String>([GeneratedImagesAlbum.name])
        if let albums = try? gallery.listAlbums() {
            for album in albums {
                titles.insert(album.name)
            }
        }

        var items: [PhotosGalleryImportItem] = []
        for title in titles.sorted() {
            let assets = SystemPhotoLibrary.imageAssets(inAlbumNamed: title)
            for asset in assets {
                guard let data = await SystemPhotoLibrary.imageData(for: asset), !data.isEmpty else {
                    continue
                }
                items.append(
                    PhotosGalleryImportItem(
                        localIdentifier: asset.localIdentifier,
                        albumTitle: title,
                        createdAt: asset.creationDate,
                        data: data
                    )
                )
            }
        }
        guard !items.isEmpty else { return 0 }
        do {
            let imported = try PhotosGalleryImporter.importItems(items, into: gallery)
            if imported > 0 {
                FeatureSettings.enableGallery()
                FeatureSettings.noteGalleryContentChanged()
            }
            return imported
        } catch {
            return 0
        }
    }

    private static var shouldSkip: Bool {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        if env["ANAIODYSSEY_MOCK_LLM"] == "1" { return true }
        if args.contains("UITEST_MOCK_LLM") { return true }
        if args.contains("UITEST_FIXTURE_MAIL") { return true }
        if args.contains("-UITestMailFixtures") { return true }
        if env["ANAIODYSSEY_UI_TEST_MAIL"] == "fixtures" { return true }
        return false
    }
}
