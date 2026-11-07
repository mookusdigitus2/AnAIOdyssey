// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class WorkspaceArchiveTests: XCTestCase {
    private var sourceContext: ModelContext!
    private var sourceRepos: RepositoryBundle!
    private var sourceGallery: URL!
    private var sourceSupport: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)")
        sourceGallery = scratch.appendingPathComponent("source-gallery", isDirectory: true)
        sourceSupport = scratch.appendingPathComponent("source-support", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = try makeStore(gallery: sourceGallery)
        sourceContext = source.0
        sourceRepos = source.1
    }

    override func tearDownWithError() throws {
        sourceContext = nil
        sourceRepos = nil
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        sourceGallery = nil
        sourceSupport = nil
    }

    func testZipStoreRoundTrip() throws {
        let url = scratch.appendingPathComponent("tiny.zip")
        try ZipStore.zip(
            files: [
                "payload.json": Data("{\"ok\":true}".utf8),
                "gallery/photo.jpg": Data([0xFF, 0xD8, 0xFF]),
            ],
            to: url
        )
        let extracted = try ZipStore.unzip(url)
        XCTAssertEqual(String(data: extracted["payload.json"] ?? Data(), encoding: .utf8), "{\"ok\":true}")
        XCTAssertEqual(extracted["gallery/photo.jpg"], Data([0xFF, 0xD8, 0xFF]))
    }

    func testExportImportRoundTripsWorkspaceDataAndSkipsEmailCalendar() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(
            id: "session-1",
            name: "Planning",
            endpointURL: "http://localhost",
            model: "test-model",
            createdAt: stamp,
            updatedAt: stamp,
            lastAccessed: stamp,
            mode: ChatSessionMode.chat.rawValue
        )
        sourceContext.insert(session)
        _ = session.addMessage(role: "user", content: "Hello")
        session.messages?.last?.timestamp = stamp

        let docsFolder = Folder(id: "folder-docs", name: "Specs", kind: .documents, createdAt: stamp, updatedAt: stamp)
        let notesFolder = Folder(id: "folder-notes", name: "Inbox", kind: .notes, createdAt: stamp, updatedAt: stamp)
        sourceContext.insert(docsFolder)
        sourceContext.insert(notesFolder)

        let document = Document(
            id: "doc-1",
            parentID: docsFolder.id,
            title: "Roadmap",
            currentContent: "v2",
            versionCount: 1,
            createdAt: stamp,
            updatedAt: stamp
        )
        sourceContext.insert(document)
        let version = DocumentVersion(
            id: "ver-1",
            document: document,
            versionNumber: 1,
            content: "v2",
            source: "user",
            createdAt: stamp
        )
        sourceContext.insert(version)
        document.versions = [version]

        let note = Note(
            id: "note-1",
            parentID: notesFolder.id,
            title: "Groceries",
            checklistItems: [ChecklistItem(text: "Milk", done: true)],
            noteType: NoteType.checklist.rawValue,
            createdAt: stamp,
            updatedAt: stamp
        )
        sourceContext.insert(note)

        let memory = Memory(id: "mem-1", text: "Prefers dark mode", createdAt: stamp)
        sourceContext.insert(memory)

        let report = ResearchReport(
            id: "research-1",
            query: "What is AnAIOdyssey?",
            summary: "A workspace.",
            sourcesJSON: "[]",
            threadJSON: "[]",
            createdAt: stamp
        )
        sourceContext.insert(report)

        let comparison = Comparison(
            id: "cmp-1",
            prompt: "Hello",
            modelA: "a",
            modelB: "b",
            responseA: "Hi",
            responseB: "Hey",
            winner: "A",
            isBlind: false
        )
        sourceContext.insert(comparison)

        let parentTask = ScheduledTask(id: "task-1", name: "Parent", createdAt: stamp, updatedAt: stamp)
        let childTask = ScheduledTask(
            id: "task-2",
            parentTaskID: parentTask.id,
            name: "Child",
            createdAt: stamp,
            updatedAt: stamp
        )
        sourceContext.insert(parentTask)
        sourceContext.insert(childTask)

        let agentTask = AgentTask(id: "agent-1", title: "Draft spec", assignment: "Write it", createdAt: stamp, updatedAt: stamp)
        sourceContext.insert(agentTask)
        sourceContext.insert(AgentTaskEvent(id: "event-1", taskID: agentTask.id, action: "created", createdAt: stamp))
        sourceContext.insert(AgentArtifact(id: "art-1", taskID: agentTask.id, title: "Note", body: "Done", createdAt: stamp, updatedAt: stamp))

        let album = try sourceRepos.gallery.createAlbum(name: "Trip", description: "Summer")
        let image = try sourceRepos.gallery.importImage(
            albumID: album.id,
            data: Data("fake-jpeg".utf8),
            suggestedFilename: "shot.jpg",
            caption: "Lake"
        )

        let draft = EmailDraft(id: "draft-secret", subject: "Secret mail", body: "Do not export")
        sourceContext.insert(draft)
        sourceContext.insert(
            CalendarEventRecord(
                id: "cal-secret",
                title: "Secret meeting",
                startDate: stamp,
                endDate: stamp.addingTimeInterval(3600),
                calendarID: "cal"
            )
        )
        try sourceContext.save()

        let exportURL = scratch.appendingPathComponent("workspace.zip")
        let exporter = WorkspaceArchiveService(
            context: sourceContext,
            repositories: sourceRepos,
            galleryDirectory: sourceGallery,
            appSupportDirectory: sourceSupport
        )
        let exportSummary = try exporter.exportArchive(to: exportURL)
        XCTAssertEqual(exportSummary.sessionCount, 1)
        XCTAssertEqual(exportSummary.messageCount, 1)
        XCTAssertEqual(exportSummary.documentCount, 1)
        XCTAssertEqual(exportSummary.noteCount, 1)
        XCTAssertEqual(exportSummary.researchReportCount, 1)
        XCTAssertEqual(exportSummary.galleryFileCount, 1)

        let unzipped = try ZipStore.unzip(exportURL)
        XCTAssertNotNil(unzipped[WorkspaceArchive.payloadFileName])
        XCTAssertNil(unzipped["email.json"])
        let payload = try JSONDecoder.archive.decode(
            WorkspaceArchive.Payload.self,
            from: unzipped[WorkspaceArchive.payloadFileName]!
        )
        XCTAssertEqual(payload.sessions.first?.name, "Planning")
        XCTAssertEqual(payload.messages.first?.content, "Hello")
        XCTAssertEqual(payload.documents.first?.title, "Roadmap")
        XCTAssertEqual(payload.notes.first?.title, "Groceries")
        XCTAssertEqual(payload.researchReports.first?.query, "What is AnAIOdyssey?")

        let destGallery = scratch.appendingPathComponent("dest-gallery", isDirectory: true)
        let destSupport = scratch.appendingPathComponent("dest-support", isDirectory: true)
        let dest = try makeStore(gallery: destGallery)
        let importer = WorkspaceArchiveService(
            context: dest.0,
            repositories: dest.1,
            galleryDirectory: destGallery,
            appSupportDirectory: destSupport
        )
        let counts = try importer.importArchive(at: exportURL)
        XCTAssertEqual(counts.sessionsImported, 1)
        XCTAssertEqual(counts.messagesImported, 1)
        XCTAssertEqual(counts.foldersImported, 2)
        XCTAssertEqual(counts.documentsImported, 1)
        XCTAssertEqual(counts.documentVersionsImported, 1)
        XCTAssertEqual(counts.notesImported, 1)
        XCTAssertEqual(counts.memoriesImported, 1)
        XCTAssertEqual(counts.researchReportsImported, 1)
        XCTAssertEqual(counts.comparisonsImported, 1)
        XCTAssertEqual(counts.tasksImported, 2)
        XCTAssertEqual(counts.agentTasksImported, 1)
        XCTAssertEqual(counts.imagesImported, 1)
        XCTAssertEqual(counts.totalSkipped, 0)

        let importedSession = try dest.1.sessions.fetchSession(id: "session-1")
        XCTAssertEqual(importedSession?.name, "Planning")
        XCTAssertEqual(try dest.1.sessions.messages(for: "session-1").map(\.content), ["Hello"])

        let importedDoc = try dest.1.documents.fetchDocument(id: "doc-1")
        XCTAssertEqual(importedDoc?.title, "Roadmap")
        XCTAssertEqual(importedDoc?.parentID, "folder-docs")
        XCTAssertEqual(importedDoc?.currentContent, "v2")
        XCTAssertEqual((importedDoc?.versions ?? []).map(\.content), ["v2"])

        let importedNote = try dest.1.notes.fetchNote(id: "note-1")
        XCTAssertEqual(importedNote?.parentID, "folder-notes")
        XCTAssertEqual(importedNote?.checklistItems.first?.text, "Milk")
        XCTAssertEqual(importedNote?.checklistItems.first?.done, true)

        XCTAssertEqual(try dest.1.memories.fetchMemory(id: "mem-1")?.text, "Prefers dark mode")
        XCTAssertEqual(try dest.1.researchReports.fetchReport(id: "research-1")?.summary, "A workspace.")
        XCTAssertEqual(try dest.1.comparisons.fetchComparison(id: "cmp-1")?.winner, "A")
        XCTAssertEqual(try dest.1.tasks.fetchTask(id: "task-2")?.parentTaskID, "task-1")
        XCTAssertEqual(try dest.1.agentTasks.fetchTask(id: "agent-1")?.title, "Draft spec")

        let importedImage = try dest.1.gallery.fetchImage(id: image.id)
        XCTAssertEqual(importedImage?.caption, "Lake")
        let importedBytes = try Data(contentsOf: dest.1.gallery.imageFileURL(for: importedImage!))
        XCTAssertEqual(String(data: importedBytes, encoding: .utf8), "fake-jpeg")

        let destDrafts = try dest.0.fetch(FetchDescriptor<EmailDraft>())
        let destEvents = try dest.0.fetch(FetchDescriptor<CalendarEventRecord>())
        XCTAssertTrue(destDrafts.isEmpty, "Email drafts must not be imported")
        XCTAssertTrue(destEvents.isEmpty, "Calendar events must not be imported")

        let second = try importer.importArchive(at: exportURL)
        XCTAssertEqual(second.totalImported, 0)
        XCTAssertGreaterThan(second.totalSkipped, 0)
        XCTAssertEqual(second.sessionsSkipped, 1)
        XCTAssertEqual(second.documentsSkipped, 1)
    }

    func testReplaceExistingErasesWorkspaceThenImports() throws {
        let destGallery = scratch.appendingPathComponent("replace-gallery", isDirectory: true)
        let destSupport = scratch.appendingPathComponent("replace-support", isDirectory: true)
        try FileManager.default.createDirectory(at: destGallery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destSupport, withIntermediateDirectories: true)
        let dest = try makeStore(gallery: destGallery)

        dest.0.insert(ChatSession(id: "old-session", name: "Keep me?", endpointURL: "http://localhost", model: "x"))
        dest.0.insert(Note(id: "old-note", title: "Stale note"))
        dest.0.insert(EmailDraft(id: "draft-keep", subject: "Keep this draft", body: "mail"))
        let oldAlbum = try dest.1.gallery.createAlbum(name: "Old Album", description: nil)
        _ = try dest.1.gallery.importImage(
            albumID: oldAlbum.id,
            data: Data("old-bytes".utf8),
            suggestedFilename: "old.jpg",
            caption: "old"
        )
        try dest.0.save()

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        sourceContext.insert(
            ChatSession(
                id: "fresh-session",
                name: "Imported",
                endpointURL: "http://localhost",
                model: "test",
                createdAt: stamp,
                updatedAt: stamp,
                lastAccessed: stamp
            )
        )
        try sourceContext.save()
        let exportURL = scratch.appendingPathComponent("replace-workspace.zip")
        let exporter = WorkspaceArchiveService(
            context: sourceContext,
            repositories: sourceRepos,
            galleryDirectory: sourceGallery,
            appSupportDirectory: sourceSupport
        )
        _ = try exporter.exportArchive(to: exportURL)

        let importer = WorkspaceArchiveService(
            context: dest.0,
            repositories: dest.1,
            galleryDirectory: destGallery,
            appSupportDirectory: destSupport
        )
        let counts = try importer.importArchive(at: exportURL, replaceExisting: true)
        XCTAssertTrue(counts.replacedExisting)
        XCTAssertGreaterThan(counts.replacedRecordCount, 0)
        XCTAssertEqual(counts.sessionsImported, 1)
        XCTAssertEqual(counts.totalSkipped, 0)
        XCTAssertNil(try dest.1.sessions.fetchSession(id: "old-session"))
        XCTAssertNil(try dest.1.notes.fetchNote(id: "old-note"))
        XCTAssertEqual(try dest.1.sessions.fetchSession(id: "fresh-session")?.name, "Imported")
        XCTAssertEqual(try dest.0.fetch(FetchDescriptor<EmailDraft>()).map(\.id), ["draft-keep"])
        XCTAssertTrue((try dest.1.gallery.listAlbums()).isEmpty)
    }

    func testImportRejectsInvalidAndUnsupportedArchives() throws {
        let importer = WorkspaceArchiveService(
            context: sourceContext,
            repositories: sourceRepos,
            galleryDirectory: sourceGallery,
            appSupportDirectory: sourceSupport
        )

        let garbage = scratch.appendingPathComponent("garbage.zip")
        try Data("not a zip".utf8).write(to: garbage)
        XCTAssertThrowsError(try importer.importArchive(at: garbage))

        let unsupported = scratch.appendingPathComponent("v99.zip")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = WorkspaceArchive.Manifest(formatVersion: 99)
        try ZipStore.zip(
            files: [
                WorkspaceArchive.manifestFileName: try encoder.encode(manifest),
                WorkspaceArchive.payloadFileName: try encoder.encode(WorkspaceArchive.Payload()),
            ],
            to: unsupported
        )
        XCTAssertThrowsError(try importer.importArchive(at: unsupported)) { error in
            guard case WorkspaceArchiveError.unsupportedVersion(99) = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    private func makeStore(gallery: URL) throws -> (ModelContext, RepositoryBundle) {
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        let context = try TestModelContainer.makeContext()
        return (context, RepositoryBundle.live(context: context, galleryDirectory: gallery))
    }
}

private extension JSONDecoder {
    static var archive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
