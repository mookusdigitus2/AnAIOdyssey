// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `GalleryRepositoryProtocol`.
///
/// Splits storage across two media: image *metadata* lives in SwiftData while
/// the image *bytes* are written as files under `galleryDirectory`. This keeps
/// the database (and any CloudKit mirror) small. Album/image cleanup must
/// therefore remove both the records and the on-disk files.
@MainActor
public final class SwiftDataGalleryRepository: GalleryRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext
    /// Directory on disk where image files are stored.
    private let galleryDirectory: URL

    /// Binds to a context and ensures the gallery directory exists (falling back
    /// to the default app-support location when none is supplied).
    public init(context: ModelContext, galleryDirectory: URL? = nil) {
        self.context = context
        let directory = galleryDirectory ?? GalleryStorageLocations.defaultGalleryDirectory()
        self.galleryDirectory = directory
        // Best-effort create; writes later surface any real failure.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func createAlbum(name: String, description: String? = nil) throws -> Album {
        let album = Album(name: name, albumDescription: description)
        context.insert(album)
        try save()
        return album
    }

    public func fetchAlbum(id: String) throws -> Album? {
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listAlbums() throws -> [Album] {
        let descriptor = FetchDescriptor<Album>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    public func updateAlbum(
        id: String,
        name: String?,
        description: String?,
        coverImageID: String?
    ) throws {
        guard let album = try fetchAlbum(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Partial update: only overwrite fields that were supplied.
        if let name {
            album.name = name
        }
        if let description {
            album.albumDescription = description
        }
        if let coverImageID {
            album.coverImageID = coverImageID
        }
        try save()
    }

    public func deleteAlbum(id: String) throws {
        guard let album = try fetchAlbum(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Delete contained images first (which also removes their files), then
        // the album record itself.
        let images = try listImages(albumID: id)
        for image in images {
            try deleteImage(id: image.id)
        }
        context.delete(album)
        try save()
    }

    @discardableResult
    public func importImage(
        albumID: String,
        data: Data,
        suggestedFilename: String? = nil,
        caption: String? = nil
    ) throws -> GalleryImage {
        // Require a valid target album before writing anything.
        guard try fetchAlbum(id: albumID) != nil else {
            throw RepositoryError.notFound(albumID)
        }

        // Convert HEIC/GIF/TIFF to PNG and sniff magic bytes so generated PNG is
        // never stored as `.jpg` (which later breaks gpt-image-1 edits).
        let stored: (data: Data, fileExtension: String)
        if let converted = try? ImageFileCodec.galleryStorageData(from: data) {
            stored = converted
        } else {
            stored = (
                data: data,
                fileExtension: ImageFileCodec.preferredFileExtension(
                    for: data,
                    suggestedFilename: suggestedFilename
                )
            )
        }
        let filename = "\(UUID().uuidString).\(stored.fileExtension)"
        let fileURL = galleryDirectory.appendingPathComponent(filename)
        // Write bytes atomically so a crash can't leave a half-written file.
        try stored.data.write(to: fileURL, options: .atomic)

        // Create the matching metadata record.
        let image = GalleryImage(albumID: albumID, filename: filename, caption: caption)
        image.contentChecksum = PhotosGalleryImporter.checksum(for: stored.data)
        context.insert(image)

        // Auto-assign this as the album cover if it doesn't have one yet.
        if let album = try fetchAlbum(id: albumID), album.coverImageID == nil {
            album.coverImageID = image.id
        }

        try save()
        return image
    }

    public func fetchImage(id: String) throws -> GalleryImage? {
        let descriptor = FetchDescriptor<GalleryImage>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listImages(albumID: String) throws -> [GalleryImage] {
        let descriptor = FetchDescriptor<GalleryImage>(
            predicate: #Predicate { $0.albumID == albumID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func updateImageCaption(id: String, caption: String?) throws {
        guard let image = try fetchImage(id: id) else {
            throw RepositoryError.notFound(id)
        }
        image.caption = caption
        try save()
    }

    public func deleteImage(id: String) throws {
        guard let image = try fetchImage(id: id) else {
            throw RepositoryError.notFound(id)
        }

        // Remove the backing file (best-effort; a missing file shouldn't block
        // deleting the record).
        let fileURL = imageFileURL(for: image)
        try? FileManager.default.removeItem(at: fileURL)

        // If this image was the album cover, re-point the cover to another image
        // (or clear it when none remain).
        if let album = try fetchAlbum(id: image.albumID), album.coverImageID == image.id {
            let remaining = try listImages(albumID: image.albumID).filter { $0.id != image.id }
            album.coverImageID = remaining.first?.id
        }

        context.delete(image)
        try save()
    }

    /// Resolves an image record to its absolute file URL within the gallery
    /// directory.
    public func imageFileURL(for image: GalleryImage) -> URL {
        galleryDirectory.appendingPathComponent(image.filename)
    }

    public func save() throws {
        try context.save()
    }
}
