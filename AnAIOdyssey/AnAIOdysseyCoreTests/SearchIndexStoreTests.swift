// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftData
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class SearchIndexStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    func testUpsertAndSearchFindsDocument() throws {
        let store = try SearchIndexStore(
            databaseURL: tempDirectory.appendingPathComponent("search.sqlite")
        )
        try store.upsert(
            kind: SearchHit.Kind.note.rawValue,
            entityID: "note-1",
            title: "Trip planning",
            body: "Book flights to Athens for July."
        )

        let hits = try store.search(query: "Athens", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.entityID, "note-1")
        XCTAssertEqual(hits.first?.title, "Trip planning")
    }

    func testDeleteRemovesIndexedRow() throws {
        let store = try SearchIndexStore(
            databaseURL: tempDirectory.appendingPathComponent("search.sqlite")
        )
        try store.upsert(
            kind: SearchHit.Kind.document.rawValue,
            entityID: "doc-1",
            title: "Budget",
            body: "Q3 forecast"
        )
        try store.delete(kind: SearchHit.Kind.document.rawValue, entityID: "doc-1")
        XCTAssertEqual(try store.count(), 0)
    }
}

final class UnifiedSearchFTSTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func makeStore() throws -> SearchIndexStore {
        try SearchIndexStore(databaseURL: tempDirectory.appendingPathComponent("search.sqlite"))
    }

    @MainActor
    func testFTSHitsMergeWithKeywordScan() throws {
        let (_, repositories) = try TestModelContainer.makeRepositories()
        _ = try repositories.notes.createNote(title: "FTS probe", content: "UniqueAnAIOdysseySearchToken")
        let store = try makeStore()
        _ = try SearchIndexBackfill.rebuildAll(repositories: repositories, store: store)

        let service = UnifiedSearchService(repositories: repositories, searchIndex: store)
        let hits = try service.search(query: "UniqueAnAIOdysseySearchToken", kinds: [.note], limit: 10)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.kind, .note)
    }

    /// Index rows for entities deleted after the last rebuild must never
    /// surface: FTS hits are verified against the live store at query time.
    @MainActor
    func testDeletedEntityFTSRowsAreFilteredOut() throws {
        let (_, repositories) = try TestModelContainer.makeRepositories()
        let note = try repositories.notes.createNote(title: "Ghost", content: "UniqueGhostToken")
        let store = try makeStore()
        _ = try SearchIndexBackfill.rebuildAll(repositories: repositories, store: store)

        try repositories.notes.deleteNote(id: note.id)

        let service = UnifiedSearchService(repositories: repositories, searchIndex: store)
        let hits = try service.search(query: "UniqueGhostToken", kinds: [.note], limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    /// A full rebuild clears rows that no longer correspond to any entity.
    @MainActor
    func testRebuildAllClearsStaleRows() throws {
        let (_, repositories) = try TestModelContainer.makeRepositories()
        let store = try makeStore()
        try store.upsert(
            kind: SearchHit.Kind.note.rawValue,
            entityID: "orphaned",
            title: "Stale",
            body: "row"
        )

        _ = try repositories.notes.createNote(title: "Fresh", content: "note")
        _ = try SearchIndexBackfill.rebuildAll(repositories: repositories, store: store)

        XCTAssertEqual(try store.count(), 1)
        XCTAssertTrue(try store.search(query: "Stale", limit: 10).isEmpty)
    }
}

@MainActor
final class SearchableProjectionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try TestModelContainer.make()
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testEmailDraftTitleFallsBackWhenSubjectBlank() throws {
        let blank = EmailDraft(subject: "   ")
        let titled = EmailDraft(subject: "Hello")
        context.insert(blank)
        context.insert(titled)
        XCTAssertEqual(blank.searchTitle, "Draft")
        XCTAssertEqual(titled.searchTitle, "Hello")
    }

    func testNoteSearchTextIncludesChecklistItems() throws {
        let note = Note(
            title: "Groceries",
            content: nil,
            checklistItems: [ChecklistItem(text: "Olive oil")],
            noteType: NoteType.checklist.rawValue
        )
        context.insert(note)
        XCTAssertTrue(note.searchText.contains("Olive oil"))
    }

    func testAgentTaskSearchTextIncludesResultSummary() throws {
        let task = AgentTask(title: "T", assignment: "Do work", resultSummary: "All done")
        context.insert(task)
        XCTAssertTrue(task.searchText.contains("Do work"))
        XCTAssertTrue(task.searchText.contains("All done"))
    }
}
