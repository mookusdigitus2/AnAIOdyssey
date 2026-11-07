// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// User-facing product and company identity.
///
/// The built app product name is `An AI Odyssey` (Mac menu bar, Dock, `.app`
/// bundle). Swift modules, Xcode targets, identifiers, and on-disk folders use
/// `AnAIOdyssey`.
public enum AppBranding {
    public static let appName = "An AI Odyssey"
    public static let companyName = "Grey Matter Ideations"
    public static let bundleIdentifier = "com.example.anaiodyssey"

    /// `UserDefaults` / iCloud KVS key prefix for current builds.
    public static let defaultsKeyPrefix = "anaiodyssey."
    /// Prefix used by pre-rename builds; copied to `defaultsKeyPrefix` on launch.
    public static let legacyDefaultsKeyPrefix = "odysseus."

    /// Application Support folder used by current builds.
    public static let applicationSupportFolderName = "AnAIOdyssey"
    /// Folder used by pre-rename builds; moved on first access when present.
    public static let legacyApplicationSupportFolderName = "Odysseus"

    /// The app's Application Support directory, migrating a legacy `Odysseus`
    /// folder into `AnAIOdyssey` when the new folder does not yet exist.
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return resolvedApplicationSupportDirectory(in: base, fileManager: fileManager)
    }

    /// Resolves `AnAIOdyssey` under `base`, moving a leftover `Odysseus` folder if needed.
    public static func resolvedApplicationSupportDirectory(
        in base: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let current = base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyApplicationSupportFolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: current.path),
           fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: current)
        }
        return current
    }
}
