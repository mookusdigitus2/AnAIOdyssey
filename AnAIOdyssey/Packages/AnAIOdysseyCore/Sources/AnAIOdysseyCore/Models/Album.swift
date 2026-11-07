// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A gallery album that groups together imported `GalleryImage` records.
///
/// Persisted via SwiftData (and mirrored to CloudKit when available). Images
/// reference their album loosely by `albumID` rather than a SwiftData
/// relationship, so deleting an album must clean up its images explicitly (see
/// `SwiftDataGalleryRepository.deleteAlbum`).
@Model
public final class Album {
    /// Stable identifier (UUID string) used as the cross-reference target for
    /// `GalleryImage.albumID` and `coverImageID`.
    public var id: String = ""
    /// User-facing album name; also the default sort key when listing albums.
    public var name: String = ""
    /// Optional longer description. Named `albumDescription` to avoid clashing
    /// with `CustomStringConvertible.description`.
    public var albumDescription: String?
    /// ID of the image used as the album's thumbnail. Auto-assigned to the first
    /// imported image and re-pointed when that image is deleted.
    public var coverImageID: String?

    /// Creates an album. `id` defaults to a fresh UUID so callers normally only
    /// supply a `name`.
    public init(
        id: String = UUID().uuidString,
        name: String,
        albumDescription: String? = nil,
        coverImageID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumDescription = albumDescription
        self.coverImageID = coverImageID
    }
}
