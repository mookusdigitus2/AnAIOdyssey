// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// The shared shape of every object that participates in unified search.
///
/// Each searchable model exposes one canonical (title, text, date) projection.
/// Live keyword scans, FTS indexing, snippets, and ranking all read these same
/// fields, so the index and live search can never drift apart per kind — adding
/// a new searchable type means one conformance plus a `SearchHit.Kind` case,
/// instead of hand-wiring the type into every search code path.
public protocol Searchable {
    /// Stable entity identifier used to route back to the object.
    var searchID: String { get }
    /// Display title for result rows (kinds provide their own fallbacks).
    var searchTitle: String { get }
    /// The full searchable text of the object — the single "to string" routine.
    var searchText: String { get }
    /// Timestamp used for recency ranking and result rows.
    var searchDate: Date? { get }
}

extension Document: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { title }
    public var searchText: String { currentContent }
    public var searchDate: Date? { updatedAt }
}

extension Note: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { title }
    public var searchText: String {
        ([content ?? ""] + checklistItems.map(\.text))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    public var searchDate: Date? { updatedAt }
}

extension ChatSession: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { name }
    public var searchText: String {
        (messages ?? []).map(\.content).joined(separator: "\n")
    }
    public var searchDate: Date? { lastMessageAt ?? updatedAt }
}

extension ScheduledTask: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { name }
    public var searchText: String { prompt ?? "" }
    public var searchDate: Date? { nextRun ?? updatedAt }
}

extension AgentTask: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { title }
    public var searchText: String {
        [assignment, contextInline, resultSummary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    public var searchDate: Date? { updatedAt }
}

extension ResearchReport: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { query }
    public var searchText: String { summary }
    public var searchDate: Date? { createdAt }
}

extension Memory: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { "Memory" }
    public var searchText: String { text }
    public var searchDate: Date? { createdAt }
}

extension EmailDraft: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { subject.nilIfEmpty ?? "Draft" }
    public var searchText: String {
        [toRecipients, ccRecipients, body]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    public var searchDate: Date? { updatedAt }
}

extension CalendarEventRecord: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { title }
    public var searchText: String {
        [notes, location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    public var searchDate: Date? { startDate }
}

extension Album: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { name }
    public var searchText: String { albumDescription ?? "" }
    public var searchDate: Date? { nil }
}

extension Comparison: Searchable {
    public var searchID: String { id }
    public var searchTitle: String { prompt }
    public var searchText: String {
        [responseA, responseB]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
    public var searchDate: Date? { votedAt }
}

public extension RepositoryBundle {
    /// Forward window for calendar events included in search and indexing.
    static let calendarSearchWindowDays = 365

    /// The canonical listing of every searchable item of `kind` — the single
    /// enumeration both live search and FTS indexing walk.
    func searchableItems(of kind: SearchHit.Kind) -> [any Searchable] {
        switch kind {
        case .document:
            return (try? documents.listLibraryDocuments()) ?? []
        case .note:
            return (try? notes.listVisibleNotes(includeArchived: false)) ?? []
        case .chat:
            return (try? sessions.listActiveSessions()) ?? []
        case .scheduledTask:
            return (try? tasks.listTasks(status: nil)) ?? []
        case .agentTask:
            return (try? agentTasks.listTasks(status: nil)) ?? []
        case .research:
            return (try? researchReports.listReports()) ?? []
        case .memory:
            return (try? memories.listMemories()) ?? []
        case .emailDraft:
            return (try? emailDrafts.listDrafts()) ?? []
        case .calendarEvent:
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: Self.calendarSearchWindowDays, to: start) ?? start
            return (try? calendarEvents.listEvents(from: start, to: end)) ?? []
        case .galleryAlbum:
            return (try? gallery.listAlbums()) ?? []
        case .comparison:
            return (try? comparisons.listComparisons()) ?? []
        }
    }

    /// Shared entity lookup by kind + id — the uniform "get" behind opening a
    /// search result and validating FTS rows against the live store.
    func fetchSearchable(kind: SearchHit.Kind, id: String) -> (any Searchable)? {
        switch kind {
        case .document:
            return (try? documents.fetchDocument(id: id)) ?? nil
        case .note:
            return (try? notes.fetchNote(id: id)) ?? nil
        case .chat:
            return (try? sessions.fetchSession(id: id)) ?? nil
        case .scheduledTask:
            return (try? tasks.fetchTask(id: id)) ?? nil
        case .agentTask:
            return (try? agentTasks.fetchTask(id: id)) ?? nil
        case .research:
            return (try? researchReports.fetchReport(id: id)) ?? nil
        case .memory:
            // Memory has no fetch-by-id in its repository; the list is small.
            return (try? memories.listMemories())?.first { $0.id == id }
        case .emailDraft:
            return (try? emailDrafts.fetchDraft(id: id)) ?? nil
        case .calendarEvent:
            return (try? calendarEvents.fetchEvent(id: id)) ?? nil
        case .galleryAlbum:
            return (try? gallery.fetchAlbum(id: id)) ?? nil
        case .comparison:
            return (try? comparisons.fetchComparison(id: id)) ?? nil
        }
    }
}

extension String {
    /// The trimmed string, or `nil` when trimming leaves nothing.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
