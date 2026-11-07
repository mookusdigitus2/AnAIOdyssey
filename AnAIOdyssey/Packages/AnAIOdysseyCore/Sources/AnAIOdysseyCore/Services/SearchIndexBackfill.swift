// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Rebuilds the FTS5 sidecar from SwiftData repositories (derived, per-device).
@MainActor
public enum SearchIndexBackfill {
    public static func databaseURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("search_index.sqlite")
    }

    /// Indexes every searchable entity when the sidecar is empty or `force` is true.
    @discardableResult
    public static func rebuildIfNeeded(
        repositories: RepositoryBundle,
        store: SearchIndexStore,
        force: Bool = false
    ) throws -> Int {
        if !force {
            let existing = (try? store.count()) ?? 0
            if existing > 0 { return 0 }
        }
        return try rebuildAll(repositories: repositories, store: store)
    }

    /// Fully rebuilds the FTS index from the shared `Searchable` projections —
    /// the exact (title, text) pairs live search matches on. Clears the index
    /// first so rows for since-deleted entities don't linger.
    @discardableResult
    public static func rebuildAll(
        repositories: RepositoryBundle,
        store: SearchIndexStore
    ) throws -> Int {
        try store.removeAll()
        var indexed = 0
        for kind in SearchHit.Kind.allCases {
            if kind == .calendarEvent, !AIDataAccess.isCalendarAllowed { continue }
            for item in repositories.searchableItems(of: kind) {
                try store.upsert(
                    kind: kind.rawValue,
                    entityID: item.searchID,
                    title: item.searchTitle,
                    body: item.searchText
                )
                indexed += 1
            }
        }
        return indexed
    }
}
