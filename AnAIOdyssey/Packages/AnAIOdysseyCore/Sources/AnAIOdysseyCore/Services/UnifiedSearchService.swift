// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// A single hit from unified search across AnAIOdyssey data sources.
public struct SearchHit: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case document
        case note
        case chat
        case scheduledTask
        case agentTask
        case research
        case memory
        case emailDraft
        case calendarEvent
        case galleryAlbum
        case comparison

        public var displayName: String {
            switch self {
            case .document: "Document"
            case .note: "Note"
            case .chat: "Chat"
            case .scheduledTask: "Task"
            case .agentTask: "Agent Task"
            case .research: "Research"
            case .memory: "Memory"
            case .emailDraft: "Email Draft"
            case .calendarEvent: "Calendar"
            case .galleryAlbum: "Gallery"
            case .comparison: "Comparison"
            }
        }

        public var systemImage: String {
            switch self {
            case .document: "doc.text"
            case .note: "note.text"
            case .chat: "bubble.left.and.bubble.right"
            case .scheduledTask: "checklist"
            case .agentTask: "cpu"
            case .research: "magnifyingglass.circle"
            case .memory: "brain.head.profile"
            case .emailDraft: "envelope"
            case .calendarEvent: "calendar"
            case .galleryAlbum: "photo.on.rectangle.angled"
            case .comparison: "arrow.left.arrow.right"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let entityID: String
    public let title: String
    public let snippet: String
    public let date: Date?
    public let score: Double

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        entityID: String,
        title: String,
        snippet: String,
        date: Date? = nil,
        score: Double = 1.0
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.title = title
        self.snippet = snippet
        self.date = date
        self.score = score
    }
}

/// Federated keyword search across every `Searchable` kind.
///
/// Live results come from one generic scan over
/// `RepositoryBundle.searchableItems(of:)`, so every kind is matched, snippeted,
/// and scored identically. FTS sidecar hits are merged in only after being
/// verified against the live store, so stale index rows (deleted or re-edited
/// entities) can never surface as ghosts.
@MainActor
public final class UnifiedSearchService {
    private let repositories: RepositoryBundle
    private let searchIndex: SearchIndexStore?

    public init(repositories: RepositoryBundle, searchIndex: SearchIndexStore? = nil) {
        self.repositories = repositories
        self.searchIndex = searchIndex
    }

    /// Searches all permitted sources, merges hits, recency-weights, and caps results.
    public func search(
        query: String,
        kinds: Set<SearchHit.Kind>? = nil,
        limit: Int = 20
    ) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = max(1, min(limit, 50))
        let allowed = kinds ?? Set(SearchHit.Kind.allCases)
        let needle = trimmed.lowercased()
        var hits: [SearchHit] = []

        for kind in SearchHit.Kind.allCases where allowed.contains(kind) && isSearchAllowed(kind) {
            for item in repositories.searchableItems(of: kind) {
                if let hit = makeHit(for: item, kind: kind, needle: needle) {
                    hits.append(hit)
                }
            }
        }

        if let searchIndex, (try? searchIndex.count()) ?? 0 > 0 {
            hits += searchFTS(query: trimmed, allowed: allowed, store: searchIndex, limit: cappedLimit * 2)
        }

        return Self.rankAndCap(Self.deduplicated(hits), limit: cappedLimit)
    }

    /// Calendar data is only searchable when the user has allowed AI access.
    private func isSearchAllowed(_ kind: SearchHit.Kind) -> Bool {
        kind != .calendarEvent || AIDataAccess.isCalendarAllowed
    }

    /// The one matcher every kind goes through: match, snippet, and score are
    /// all computed from the item's `Searchable` projection.
    private func makeHit(for item: any Searchable, kind: SearchHit.Kind, needle: String) -> SearchHit? {
        let title = item.searchTitle
        let text = item.searchText
        guard matches(needle, in: title, text) else { return nil }
        return SearchHit(
            kind: kind,
            entityID: item.searchID,
            title: title,
            snippet: snippet(for: text, matching: needle),
            date: item.searchDate,
            score: score(for: title, body: text, needle: needle, date: item.searchDate)
        )
    }

    /// FTS hits are verified against the live store: rows whose entity no longer
    /// exists are dropped, and title/date/score come from the live object so a
    /// stale row can never outrank fresh data. A small bonus rewards rows the
    /// tokenizer matched.
    private func searchFTS(
        query: String,
        allowed: Set<SearchHit.Kind>,
        store: SearchIndexStore,
        limit: Int
    ) -> [SearchHit] {
        let ftsQuery = Self.ftsMatchQuery(from: query)
        guard let rows = try? store.search(query: ftsQuery, limit: limit) else { return [] }
        let needle = query.lowercased()
        return rows.compactMap { row in
            guard let kind = SearchHit.Kind(rawValue: row.kind),
                  allowed.contains(kind),
                  isSearchAllowed(kind),
                  let item = repositories.fetchSearchable(kind: kind, id: row.entityID)
            else { return nil }

            let text = item.searchText
            // Prefer a live snippet; fall back to the index's own when the
            // needle only matched via FTS tokenization (e.g. multi-word OR).
            let snippetText = text.localizedCaseInsensitiveContains(needle)
                ? snippet(for: text, matching: needle)
                : row.snippet
                    .replacingOccurrences(of: "<b>", with: "")
                    .replacingOccurrences(of: "</b>", with: "")
            return SearchHit(
                kind: kind,
                entityID: item.searchID,
                title: item.searchTitle,
                snippet: snippetText,
                date: item.searchDate,
                score: score(for: item.searchTitle, body: text, needle: needle, date: item.searchDate) + 1.0
            )
        }
    }

    private static func ftsMatchQuery(from query: String) -> String {
        let tokens = query
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private static func deduplicated(_ hits: [SearchHit]) -> [SearchHit] {
        var bestByKey: [String: SearchHit] = [:]
        for hit in hits {
            let key = "\(hit.kind.rawValue)|\(hit.entityID)"
            if let existing = bestByKey[key] {
                if hit.score > existing.score {
                    bestByKey[key] = hit
                }
            } else {
                bestByKey[key] = hit
            }
        }
        return Array(bestByKey.values)
    }

    private func matches(_ needle: String, in fields: String...) -> Bool {
        fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func snippet(for text: String, matching needle: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = collapsed.range(of: needle, options: .caseInsensitive) else {
            return String(collapsed.prefix(120))
        }
        let start = collapsed.index(range.lowerBound, offsetBy: -40, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(range.upperBound, offsetBy: 60, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var piece = String(collapsed[start..<end])
        if start > collapsed.startIndex { piece = "…" + piece }
        if end < collapsed.endIndex { piece += "…" }
        return piece
    }

    private func score(for title: String, body: String, needle: String, date: Date?) -> Double {
        var value = 0.0
        if title.localizedCaseInsensitiveContains(needle) { value += 3 }
        if body.localizedCaseInsensitiveContains(needle) { value += 1 }
        if let date {
            let age = -date.timeIntervalSinceNow
            value += max(0, 1 - age / (60 * 60 * 24 * 30))
        }
        return value
    }

    private static func rankAndCap(_ hits: [SearchHit], limit: Int) -> [SearchHit] {
        Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}
