// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import CryptoKit
import Foundation

/// One image pulled from the system Photos library, ready to merge into the
/// in-app gallery.
public struct PhotosGalleryImportItem: Sendable, Equatable {
    public let localIdentifier: String
    public let albumTitle: String
    public let createdAt: Date?
    public let data: Data

    public init(localIdentifier: String, albumTitle: String, createdAt: Date?, data: Data) {
        self.localIdentifier = localIdentifier
        self.albumTitle = albumTitle
        self.createdAt = createdAt
        self.data = data
    }
}

/// Merges Photos-library images into the in-app gallery without duplicating
/// files that already exist (or CloudKit metadata whose bytes never synced).
@MainActor
public enum PhotosGalleryImporter {
    /// SHA-256 hex digest of gallery-stored image bytes.
    public static func checksum(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Imports `items` into `gallery`. Returns how many images were added or
    /// had missing files filled in.
    @discardableResult
    public static func importItems(
        _ items: [PhotosGalleryImportItem],
        into gallery: any GalleryRepositoryProtocol
    ) throws -> Int {
        try backfillChecksums(in: gallery)
        var imported = 0
        for item in items {
            if try importItem(item, into: gallery) {
                imported += 1
            }
        }
        try collapseDuplicates(in: gallery)
        if imported > 0 {
            try gallery.save()
        }
        return imported
    }

    private static func importItem(
        _ item: PhotosGalleryImportItem,
        into gallery: any GalleryRepositoryProtocol
    ) throws -> Bool {
        let stored: (data: Data, fileExtension: String)
        if let converted = try? ImageFileCodec.galleryStorageData(from: item.data) {
            stored = converted
        } else {
            return false
        }
        let checksum = checksum(for: stored.data)
        let album = try resolvedAlbum(named: item.albumTitle, in: gallery)
        let images = try gallery.listImages(albumID: album.id)

        if let existing = try matchingImage(checksum: checksum, identifier: item.localIdentifier, in: gallery) {
            existing.photosAssetIdentifier = existing.photosAssetIdentifier ?? item.localIdentifier
            existing.contentChecksum = existing.contentChecksum ?? checksum
            if fileExists(existing, gallery: gallery) {
                try gallery.save()
                return false
            }
            try stored.data.write(to: gallery.imageFileURL(for: existing), options: .atomic)
            try gallery.save()
            return true
        }

        if let hole = bestHole(in: images, matching: item.createdAt, gallery: gallery) {
            try stored.data.write(to: gallery.imageFileURL(for: hole), options: .atomic)
            hole.contentChecksum = checksum
            hole.photosAssetIdentifier = item.localIdentifier
            try gallery.save()
            return true
        }

        let image = try gallery.importImage(
            albumID: album.id,
            data: stored.data,
            suggestedFilename: "photo.\(stored.fileExtension)",
            caption: nil
        )
        image.photosAssetIdentifier = item.localIdentifier
        image.contentChecksum = checksum
        if let createdAt = item.createdAt {
            image.createdAt = createdAt
        }
        try gallery.save()
        return true
    }

    private static func matchingImage(
        checksum: String,
        identifier: String,
        in gallery: any GalleryRepositoryProtocol
    ) throws -> GalleryImage? {
        let images = try allImages(in: gallery)
        if let byID = images.first(where: { $0.photosAssetIdentifier == identifier }) {
            return byID
        }
        return images.first(where: { $0.contentChecksum == checksum })
    }

    private static func bestHole(
        in images: [GalleryImage],
        matching date: Date?,
        gallery: any GalleryRepositoryProtocol
    ) -> GalleryImage? {
        let holes = images.filter { !fileExists($0, gallery: gallery) }
        guard !holes.isEmpty else { return nil }
        guard let date else { return holes.last }
        return holes.min { lhs, rhs in
            abs(lhs.createdAt.timeIntervalSince(date)) < abs(rhs.createdAt.timeIntervalSince(date))
        }
    }

    private static func resolvedAlbum(
        named title: String,
        in gallery: any GalleryRepositoryProtocol
    ) throws -> Album {
        let matches = try gallery.listAlbums().filter { $0.name == title }
        if matches.isEmpty {
            if title == GeneratedImagesAlbum.name {
                return try GeneratedImagesAlbum.findOrCreate(in: gallery)
            }
            return try gallery.createAlbum(name: title, description: nil)
        }
        let primary = matches[0]
        for extra in matches.dropFirst() {
            for image in try gallery.listImages(albumID: extra.id) {
                image.albumID = primary.id
            }
            try gallery.save()
            try gallery.deleteAlbum(id: extra.id)
        }
        return primary
    }

    private static func backfillChecksums(in gallery: any GalleryRepositoryProtocol) throws {
        var changed = false
        for image in try allImages(in: gallery) {
            guard image.contentChecksum == nil else { continue }
            let url = gallery.imageFileURL(for: image)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            image.contentChecksum = checksum(for: data)
            changed = true
        }
        if changed {
            try gallery.save()
        }
    }

    private static func collapseDuplicates(in gallery: any GalleryRepositoryProtocol) throws {
        var grouped: [String: [GalleryImage]] = [:]
        for image in try allImages(in: gallery) {
            guard let checksum = image.contentChecksum, !checksum.isEmpty else { continue }
            grouped[checksum, default: []].append(image)
        }
        for group in grouped.values where group.count > 1 {
            let ranked = group.sorted { lhs, rhs in
                let lhsCaption = !(lhs.caption ?? "").isEmpty
                let rhsCaption = !(rhs.caption ?? "").isEmpty
                if lhsCaption != rhsCaption { return lhsCaption && !rhsCaption }
                let lhsFile = fileExists(lhs, gallery: gallery)
                let rhsFile = fileExists(rhs, gallery: gallery)
                if lhsFile != rhsFile { return lhsFile && !rhsFile }
                return lhs.createdAt < rhs.createdAt
            }
            guard let keeper = ranked.first else { continue }
            let keeperURL = gallery.imageFileURL(for: keeper)
            if !FileManager.default.fileExists(atPath: keeperURL.path),
               let donor = ranked.dropFirst().first(where: { fileExists($0, gallery: gallery) }) {
                try FileManager.default.copyItem(at: gallery.imageFileURL(for: donor), to: keeperURL)
            }
            for extra in ranked.dropFirst() {
                try gallery.deleteImage(id: extra.id)
            }
        }
    }

    private static func allImages(in gallery: any GalleryRepositoryProtocol) throws -> [GalleryImage] {
        try gallery.listAlbums().flatMap { try gallery.listImages(albumID: $0.id) }
    }

    private static func fileExists(_ image: GalleryImage, gallery: any GalleryRepositoryProtocol) -> Bool {
        FileManager.default.fileExists(atPath: gallery.imageFileURL(for: image).path)
    }
}
