// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Resolves on-disk locations for gallery image files.
///
/// Centralizes the directory layout so the gallery repository (and tests) agree
/// on where image bytes live. Image *files* are stored here; their *metadata*
/// lives in SwiftData.
public enum GalleryStorageLocations {
    /// The "Gallery" subfolder within a given app-support directory (injectable
    /// for tests).
    public static func galleryDirectory(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("Gallery", isDirectory: true)
    }

    /// The app's base support directory (`…/Application Support/AnAIOdyssey`).
    ///
    /// Migrates a leftover `Odysseus` folder from earlier builds when present.
    public static func defaultAppSupportDirectory() -> URL {
        AppBranding.applicationSupportDirectory()
    }

    /// The production gallery directory under the default app-support location.
    public static func defaultGalleryDirectory() -> URL {
        galleryDirectory(appSupportDirectory: defaultAppSupportDirectory())
    }
}
