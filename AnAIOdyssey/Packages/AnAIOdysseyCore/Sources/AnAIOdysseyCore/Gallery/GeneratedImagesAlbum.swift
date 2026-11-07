// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// The album that collects AI-generated (and AI-edited) images in the photos
/// gallery database.
public enum GeneratedImagesAlbum {
    public static let name = "AI Generated"
    public static let albumDescription = "Images created by AI image models"

    /// Finds the generated-images album, or creates it when the gallery is empty
    /// of that name.
    @MainActor
    public static func findOrCreate(in gallery: any GalleryRepositoryProtocol) throws -> Album {
        if let existing = try gallery.listAlbums().first(where: { $0.name == name }) {
            return existing
        }
        return try gallery.createAlbum(name: name, description: albumDescription)
    }
}
