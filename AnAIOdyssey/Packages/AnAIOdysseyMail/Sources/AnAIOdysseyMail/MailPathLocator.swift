// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Resolves the on-disk locations of Apple Mail's local data store.
///
/// Apple Mail keeps its account data under `~/Library/Mail/V<n>/` where `<n>` is a
/// schema version that changes between macOS releases. This namespace centralizes
/// the logic for discovering the current version directory, the SQLite "Envelope
/// Index" database, and individual `.emlx` message files so callers don't hardcode
/// fragile paths. All members are stateless static helpers and accept injectable
/// `FileManager`/home-directory parameters to keep them testable.
public enum MailPathLocator {
    /// The current user's home directory. Apple Mail's local store only exists on
    /// macOS; on iOS this returns the app sandbox home so the API still compiles
    /// (Mail detection then simply finds nothing).
    public static var defaultHomeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// The root `~/Library/Mail` directory that contains the versioned Mail stores.
    public static func mailLibraryDirectory(homeDirectory: URL = MailPathLocator.defaultHomeDirectory) -> URL {
        homeDirectory.appendingPathComponent("Library/Mail", isDirectory: true)
    }

    /// Finds the newest `V<n>` Mail data directory, or `nil` if Mail isn't set up.
    ///
    /// Multiple version directories can coexist after macOS upgrades, so we pick the
    /// highest-numbered one (the one Mail currently uses) by sorting descending.
    public static func detectMailVersionDirectory(
        fileManager: FileManager = .default,
        homeDirectory: URL = MailPathLocator.defaultHomeDirectory
    ) -> URL? {
        let mailRoot = mailLibraryDirectory(homeDirectory: homeDirectory)
        // Read the Mail library contents; a throw here (e.g. missing dir or no
        // permission) simply means there's no detectable Mail store.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Keep only the "V<n>" version directories and return the highest version.
        return entries
            .filter { $0.lastPathComponent.hasPrefix("V") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .first
    }

    /// Locates the SQLite `Envelope Index` database, or `nil` if it's absent.
    ///
    /// The Envelope Index lives at `V<n>/MailData/Envelope Index` and backs the
    /// mailbox/message listings. Returns `nil` unless the file actually exists.
    public static func envelopeIndexURL(
        fileManager: FileManager = .default,
        homeDirectory: URL = MailPathLocator.defaultHomeDirectory
    ) -> URL? {
        // Without a version directory there is no database to point at.
        guard let versionDirectory = detectMailVersionDirectory(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }

        // Build the canonical Envelope Index path within the version directory.
        let candidate = versionDirectory
            .appendingPathComponent("MailData", isDirectory: true)
            .appendingPathComponent("Envelope Index", isDirectory: false)

        // Only surface the path if the database is really present on disk.
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Searches the Mail version directory for the `.emlx` file of a given message.
    ///
    /// The Envelope Index stores only metadata; full message bodies live in
    /// per-message `.emlx` files scattered across mailbox subfolders. This walks the
    /// tree looking for either the complete (`<id>.emlx`) or partially-downloaded
    /// (`<id>.partial.emlx`) variant. Returns `nil` when neither is found.
    public static func locateEmlxFile(
        messageID: Int64,
        fileManager: FileManager = .default,
        homeDirectory: URL = MailPathLocator.defaultHomeDirectory
    ) -> URL? {
        // No version directory means there are no message files to search.
        guard let versionDirectory = detectMailVersionDirectory(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }

        // Accept either the full or the partially-downloaded message filename.
        let filename = "\(messageID).emlx"
        let partialFilename = "\(messageID).partial.emlx"
        // Recursively walk the version directory and return the first match.
        if let enumerator = fileManager.enumerator(
            at: versionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                switch fileURL.lastPathComponent {
                case filename, partialFilename:
                    return fileURL
                default:
                    continue
                }
            }
        }

        // No matching message file exists anywhere under the version directory.
        return nil
    }
}
