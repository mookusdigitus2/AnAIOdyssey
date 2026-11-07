// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class RepositoryTests: XCTestCase {
    private var context: ModelContext!
    private var sessions: SessionRepositoryProtocol!
    private var documents: DocumentRepositoryProtocol!
    private var notes: NoteRepositoryProtocol!

    override func setUpWithError() throws {
        let bundle = try TestModelContainer.makeRepositories()
        context = bundle.0
        let repos = bundle.1
        sessions = repos.sessions
        documents = repos.documents
        notes = repos.notes
    }

    override func tearDownWithError() throws {
        context = nil
        sessions = nil
        documents = nil
        notes = nil
    }

    func testSessionRepositoryCreateAndFetch() throws {
        let created = try sessions.createSession(
            name: "Planning",
            endpointURL: "http://localhost:8080",
            model: "llama-3.2",
            owner: "mark"
        )

        let fetched = try sessions.fetchSession(id: created.id)
        XCTAssertEqual(fetched?.name, "Planning")

        try sessions.renameSession(id: created.id, name: "Planning v2")
        let renamed = try sessions.fetchSession(id: created.id)
        XCTAssertEqual(renamed?.name, "Planning v2")
    }

    func testSessionRepositoryListSortedByLastMessage() throws {
        let older = try sessions.createSession(
            name: "Older",
            endpointURL: "http://localhost",
            model: "a",
            owner: nil
        )
        let newer = try sessions.createSession(
            name: "Newer",
            endpointURL: "http://localhost",
            model: "b",
            owner: nil
        )

        older.lastMessageAt = Date(timeIntervalSince1970: 100)
        newer.lastMessageAt = Date(timeIntervalSince1970: 200)
        try sessions.save()

        let listed = try sessions.listActiveSessions()
        XCTAssertEqual(listed.map(\.name), ["Newer", "Older"])
    }

    func testDocumentRepositoryOpenTabs() throws {
        let first = try documents.createDocument(title: "One", content: "1")
        let second = try documents.createDocument(title: "Two", content: "2")
        let third = try documents.createDocument(title: "Three", content: "3")

        try documents.openTab(documentID: first.id)
        try documents.openTab(documentID: second.id)
        try documents.openTab(documentID: third.id)

        var openTabs = try documents.listOpenTabs()
        XCTAssertEqual(openTabs.count, 3)
        XCTAssertEqual(openTabs.map(\.title), ["One", "Two", "Three"])

        try documents.closeTab(documentID: second.id)
        openTabs = try documents.listOpenTabs()
        XCTAssertEqual(openTabs.count, 2)
        XCTAssertEqual(openTabs.map(\.title), ["One", "Three"])
    }

    func testNoteRepositoryPinAndArchive() throws {
        let pinned = try notes.createNote(title: "Pinned", content: "A")
        _ = try notes.createNote(title: "Regular", content: "B")
        let archived = try notes.createNote(title: "Archived", content: "C")

        try notes.setPinned(id: pinned.id, pinned: true)
        try notes.setArchived(id: archived.id, archived: true)

        let visible = try notes.listVisibleNotes(includeArchived: false)
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.first?.title, "Pinned")
        XCTAssertTrue(visible.first?.pinned == true)
        XCTAssertFalse(visible.contains { $0.title == "Archived" })

        let all = try notes.listVisibleNotes(includeArchived: true)
        XCTAssertEqual(all.count, 3)
    }

    func testRepositoryIsolation() throws {
        _ = try sessions.createSession(
            name: "Isolated",
            endpointURL: "http://localhost",
            model: "test",
            owner: nil
        )

        let other = try TestModelContainer.makeRepositories()
        let otherSessions = other.1.sessions
        let listed = try otherSessions.listActiveSessions()
        XCTAssertTrue(listed.isEmpty)
    }
}
