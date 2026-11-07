// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// On-disk snapshot of the unified mail reader's in-memory cache and id maps.
///
/// Saved after successful background refreshes so the Email tab can render
/// immediately on the next launch while a network update runs asynchronously.
struct UnifiedMailCacheSnapshot: Codable, Equatable {
    struct MailboxMapping: Codable, Equatable {
        let childIndex: Int
        let childMailboxID: Int64
    }

    struct MessageMapping: Codable, Equatable {
        let childIndex: Int
        let childMessageID: Int64
    }

    let accountFingerprint: String
    let mailboxes: [MailMailbox]
    let messagesByMailbox: [String: [MailMessageSummary]]
    let nextMailboxGlobalID: Int64
    let nextMessageGlobalID: Int64
    let mailboxKeyToGlobal: [String: Int64]
    let globalToMailbox: [String: MailboxMapping]
    let messageKeyToGlobal: [String: Int64]
    let globalToMessage: [String: MessageMapping]
    /// Per-account Gmail id-mapper state (keyed by account id), so child readers
    /// rebuilt after a relaunch resolve cached numeric ids to the same Gmail
    /// messages. Optional so cache files written by older builds still decode.
    var gmailMappersByAccountID: [String: GmailIDMapperState]? = nil
}

/// Reads and writes the unified mail cache under Application Support.
enum EmailCachePersistence {
    static func cacheFileURL(
        fileManager: FileManager = .default,
        appSupportDirectory: URL? = nil
    ) -> URL {
        let folder: URL
        if let appSupportDirectory {
            folder = appSupportDirectory.appendingPathComponent(
                AppBranding.applicationSupportFolderName,
                isDirectory: true
            )
        } else {
            folder = AppBranding.applicationSupportDirectory(fileManager: fileManager)
        }
        return folder.appendingPathComponent("email-cache.json")
    }

    static func save(
        _ snapshot: UnifiedMailCacheSnapshot,
        fileManager: FileManager = .default,
        appSupportDirectory: URL? = nil
    ) {
        let url = cacheFileURL(fileManager: fileManager, appSupportDirectory: appSupportDirectory)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Cache persistence is best-effort; a failed write must not affect mail reads.
        }
    }

    static func load(
        fileManager: FileManager = .default,
        appSupportDirectory: URL? = nil
    ) -> UnifiedMailCacheSnapshot? {
        let url = cacheFileURL(fileManager: fileManager, appSupportDirectory: appSupportDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UnifiedMailCacheSnapshot.self, from: data)
    }
}
