// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Photos
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Writes images into the device Photos library (iPhone, iPad, and Mac).
///
/// Full library access is required to create the “AI Generated” album; add-only
/// access can still drop images into Recents. In-app gallery storage does not
/// depend on this — Photos is a best-effort mirror so generated pictures show
/// up in the system Photos app.
public enum SystemPhotoLibrary {
    public enum LibraryError: Error, LocalizedError, Equatable {
        case invalidImage
        case accessDenied
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidImage:
                "This file is not a photo Photos can store."
            case .accessDenied:
                "Photos access is turned off. Enable it in Settings to save images to your Photos library."
            case .saveFailed(let detail):
                detail
            }
        }
    }

    /// Current read/write Photos authorization, without prompting.
    public static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// True when we can read the library (full or limited picker access).
    public static var canReadPhotos: Bool {
        switch authorizationStatus {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// True when we can add assets (full, limited, or add-only).
    public static var canAddPhotos: Bool {
        if canReadPhotos { return true }
        return PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    /// True when the user allowed saving photos but not reading the library.
    public static var isAddOnly: Bool {
        canAddPhotos && !canReadPhotos
    }

    /// Prompts for read/write access, including upgrading add-only grants.
    public static func requestAccess() async -> Bool {
        if canReadPhotos { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Opens the system Settings page so the user can switch Photos to Full Access.
    @MainActor
    public static func openAppSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else {
            return
        }
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Saves `data` into the named Photos album when the user has allowed access.
    ///
    /// Returns `false` (and does not throw) when access is denied so generation
    /// can still succeed in the in-app gallery.
    @discardableResult
    public static func saveImageIfAllowed(
        _ data: Data,
        albumName: String = GeneratedImagesAlbum.name
    ) async -> Bool {
        do {
            try await saveImage(data, albumName: albumName)
            return true
        } catch {
            return false
        }
    }

    /// Saves `data` into `albumName`, creating the album when needed.
    public static func saveImage(
        _ data: Data,
        albumName: String = GeneratedImagesAlbum.name
    ) async throws {
        let prepared = try preparedImageData(data)
        // Ask for full access first so images can land in a named album. If the
        // user already granted add-only (or declines read), we still write to Recents.
        if !canReadPhotos {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard canAddPhotos else { throw LibraryError.accessDenied }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(prepared.fileExtension)")
        try prepared.data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        if authorizationStatus == .authorized {
            do {
                try await saveFile(fileURL, intoAlbumNamed: albumName)
                return
            } catch {
                try await saveFileToRecents(fileURL)
                return
            }
        }
        try await saveFileToRecents(fileURL)
    }

    /// Re-encodes unsupported formats (HEIC → PNG) so Photos will accept the file.
    static func preparedImageData(_ data: Data) throws -> (data: Data, fileExtension: String) {
        if let converted = try? ImageFileCodec.galleryStorageData(from: data) {
            return converted
        }
        throw LibraryError.invalidImage
    }

    private static func saveFile(_ fileURL: URL, intoAlbumNamed name: String) async throws {
        let collection = try await findOrCreateAlbum(named: name)
        var didCreate = false
        try await PHPhotoLibrary.shared().performChanges {
            guard let assetRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL),
                  let placeholder = assetRequest.placeholderForCreatedAsset,
                  let albumRequest = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            albumRequest.addAssets(NSArray(object: placeholder))
            didCreate = true
        }
        if !didCreate {
            throw LibraryError.saveFailed("Photos could not store this image in “\(name)”.")
        }
    }

    private static func saveFileToRecents(_ fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
    }

    private static func findOrCreateAlbum(named title: String) async throws -> PHAssetCollection {
        if let existing = fetchAlbum(named: title) {
            return existing
        }
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        if let id = placeholder?.localIdentifier,
           let created = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id],
            options: nil
           ).firstObject {
            return created
        }
        if let existing = fetchAlbum(named: title) {
            return existing
        }
        throw LibraryError.saveFailed("Could not create the “\(title)” album in Photos.")
    }

    /// Image assets in a user album with this title (empty when the album is missing).
    public static func imageAssets(inAlbumNamed title: String) -> [PHAsset] {
        guard canReadPhotos, let collection = fetchAlbum(named: title) else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image {
                assets.append(asset)
            }
        }
        return assets
    }

    /// Full-resolution image bytes, allowing iCloud Photos to download if needed.
    public static func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.version = .current
            options.isSynchronous = false
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(returning: nil)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func fetchAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: options
        ).firstObject
    }
}
