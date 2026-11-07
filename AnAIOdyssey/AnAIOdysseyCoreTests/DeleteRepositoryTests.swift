// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class DeleteRepositoryTests: XCTestCase {
    private var context: ModelContext!
    private var sessions: SessionRepositoryProtocol!
    private var documents: DocumentRepositoryProtocol!
    private var notes: NoteRepositoryProtocol!

    override func setUpWithError() throws {
        let bundle = try TestModelContainer.makeRepositories()
        context = bundle.0
        sessions = bundle.1.sessions
        documents = bundle.1.documents
        notes = bundle.1.notes
    }

    func testDeleteSessionRemovesMessages() throws {
        let session = try sessions.createSession(
            name: "Temporary",
            endpointURL: "http://localhost",
            model: "test",
            owner: nil
        )
        _ = try sessions.addMessage(sessionID: session.id, role: "user", content: "Hello")
        try sessions.deleteSession(id: session.id)

        XCTAssertNil(try sessions.fetchSession(id: session.id))
        XCTAssertTrue(try sessions.messages(for: session.id).isEmpty)
        XCTAssertTrue(try sessions.listActiveSessions().isEmpty)
    }

    func testDeleteSessionNotFoundThrows() {
        XCTAssertThrowsError(try sessions.deleteSession(id: "missing-session")) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound("missing-session"))
        }
    }

    func testDeleteSessionRemovesOnlyTargetSession() throws {
        let keep = try sessions.createSession(
            name: "Keep",
            endpointURL: "http://localhost",
            model: "a",
            owner: nil
        )
        let remove = try sessions.createSession(
            name: "Remove",
            endpointURL: "http://localhost",
            model: "b",
            owner: nil
        )

        try sessions.deleteSession(id: remove.id)

        XCTAssertNotNil(try sessions.fetchSession(id: keep.id))
        XCTAssertNil(try sessions.fetchSession(id: remove.id))
    }

    func testDeleteDocumentRemovesVersions() throws {
        let document = try documents.createDocument(title: "Draft", content: "v1")
        _ = document.saveContent("v2")
        try documents.deleteDocument(id: document.id)

        XCTAssertNil(try documents.fetchDocument(id: document.id))
    }

    func testDeleteDocumentRemovesOpenTab() throws {
        let document = try documents.createDocument(title: "Open Tab", content: "body")
        try documents.openTab(documentID: document.id)

        var openTabs = try documents.listOpenTabs()
        XCTAssertEqual(openTabs.count, 1)

        try documents.deleteDocument(id: document.id)

        openTabs = try documents.listOpenTabs()
        XCTAssertTrue(openTabs.isEmpty)
        XCTAssertNil(try documents.fetchDocument(id: document.id))
    }

    func testDeleteDocumentNotFoundThrows() {
        XCTAssertThrowsError(try documents.deleteDocument(id: "missing-document")) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound("missing-document"))
        }
    }

    func testDeleteNote() throws {
        let note = try notes.createNote(title: "Trash me", content: "Bye")
        try notes.deleteNote(id: note.id)

        XCTAssertNil(try notes.fetchNote(id: note.id))
        XCTAssertFalse(try notes.listVisibleNotes(includeArchived: true).contains { $0.id == note.id })
    }

    func testDeleteArchivedNote() throws {
        let note = try notes.createNote(title: "Archived", content: "Later")
        try notes.setArchived(id: note.id, archived: true)
        try notes.deleteNote(id: note.id)

        XCTAssertNil(try notes.fetchNote(id: note.id))
    }

    func testDeleteNoteNotFoundThrows() {
        XCTAssertThrowsError(try notes.deleteNote(id: "missing-note")) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound("missing-note"))
        }
    }
}
