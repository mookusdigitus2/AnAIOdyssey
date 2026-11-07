// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class ModelTests: XCTestCase {
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

    func testCreateChatSessionWithMessages() throws {
        let session = ChatSession(
            name: "Test Chat",
            endpointURL: "http://localhost",
            model: "llama-3.2"
        )
        context.insert(session)

        _ = session.addMessage(role: "user", content: "Hello")
        _ = session.addMessage(role: "assistant", content: "Hi there")
        try context.save()

        let sessionID = session.id
        let fetched = try context.fetch(
            FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.messages?.count, 2)
        XCTAssertEqual(fetched.first?.messageCount, 2)
        XCTAssertNotNil(fetched.first?.lastMessageAt)
    }

    func testDocumentVersionHistory() throws {
        let document = Document(title: "Draft", currentContent: "v0")
        context.insert(document)

        _ = document.saveContent("v1", summary: "First edit", source: "user")
        _ = document.saveContent("v2", summary: "Second edit", source: "ai")
        try context.save()

        let sortedVersions = (document.versions ?? []).sorted { $0.versionNumber < $1.versionNumber }
        XCTAssertEqual(sortedVersions.count, 2)
        XCTAssertEqual(document.versionCount, 2)
        XCTAssertEqual(document.currentContent, "v2")
        XCTAssertEqual(sortedVersions.map(\.versionNumber), [1, 2])
        XCTAssertEqual(sortedVersions.map(\.content), ["v1", "v2"])
        XCTAssertEqual(sortedVersions.last?.source, "ai")
    }

    func testNoteChecklistItems() throws {
        let note = Note(
            title: "Groceries",
            checklistItems: [
                ChecklistItem(text: "Milk", done: false),
                ChecklistItem(text: "Bread", done: true),
            ],
            noteType: NoteType.checklist.rawValue
        )
        context.insert(note)
        try context.save()

        let noteID = note.id
        note.toggleChecklistItem(at: 0)
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
        ).first
        XCTAssertEqual(fetched?.checklistItems.count, 2)
        XCTAssertEqual(fetched?.checklistItems[0].text, "Milk")
        XCTAssertTrue(fetched?.checklistItems[0].done == true)
        XCTAssertTrue(fetched?.checklistItems[1].done == true)
    }

    func testCascadeDeleteSession() throws {
        let session = ChatSession(
            name: "Ephemeral",
            endpointURL: "http://localhost",
            model: "test"
        )
        context.insert(session)
        _ = session.addMessage(role: "user", content: "temp")
        try context.save()

        let sessionID = session.id
        let messageID = session.messages!.first!.id
        context.delete(session)
        try context.save()

        let sessions = try context.fetch(
            FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })
        )
        let messages = try context.fetch(
            FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == messageID })
        )
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    func testDocumentArchiveFlag() throws {
        let active = Document(title: "Active")
        let archived = Document(title: "Archived", archived: true)
        context.insert(active)
        context.insert(archived)
        try context.save()

        let activeDocs = try context.fetch(DocumentFetch.activeDocuments())
        XCTAssertEqual(activeDocs.count, 1)
        XCTAssertEqual(activeDocs.first?.title, "Active")
    }

    func testChatMessageGalleryMetadataRoundTrip() {
        let encoded = ChatMessageGalleryMetadata.encode(galleryImageID: "img-42")
        XCTAssertEqual(ChatMessageGalleryMetadata.galleryImageID(from: encoded), "img-42")
        XCTAssertNil(ChatMessageGalleryMetadata.galleryImageID(from: nil))
        XCTAssertNil(ChatMessageGalleryMetadata.galleryImageID(from: "not-json"))
    }
}
