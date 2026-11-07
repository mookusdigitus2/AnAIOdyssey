// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Metadata record for a single image in the gallery.
///
/// Only the *metadata* lives in SwiftData/CloudKit; the actual image bytes are
/// written to disk by `SwiftDataGalleryRepository` (keeping the database small
/// and CloudKit-friendly). `filename` is the link between this record and the
/// file on disk.
@Model
public final class GalleryImage {
    /// Stable identifier (UUID string), also referenced by `Album.coverImageID`.
    public var id: String = ""
    /// ID of the owning `Album`. A loose reference rather than a SwiftData
    /// relationship.
    public var albumID: String = ""
    /// On-disk filename within the gallery directory. Resolve to a full URL via
    /// `GalleryRepositoryProtocol.imageFileURL(for:)`.
    public var filename: String = ""
    /// Optional user/AI-supplied caption.
    public var caption: String?
    /// SHA-256 of the stored file bytes, used to skip Photos re-imports.
    public var contentChecksum: String?
    /// This device's Photos `localIdentifier`, when the image was pulled from Photos.
    public var photosAssetIdentifier: String?
    /// Import timestamp, used to sort images newest-first.
    public var createdAt: Date = Date()

    /// Creates an image metadata record; `id` defaults to a fresh UUID.
    public init(
        id: String = UUID().uuidString,
        albumID: String,
        filename: String,
        caption: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.albumID = albumID
        self.filename = filename
        self.caption = caption
        self.createdAt = createdAt
    }
}
