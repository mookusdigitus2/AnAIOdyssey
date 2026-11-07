// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Exports and imports workspace data (chats, documents, notes, research, and
/// related records) as a zip archive. Email drafts and calendar events are
/// never written or read.
///
/// Imports are idempotent by default: records whose ids already exist are
/// skipped, so a repeated import is safe. Pass `replaceExisting: true` to
/// erase archive-covered workspace content first (email drafts and calendar
/// events are left alone). Gallery image bytes and agent-task context files
/// travel alongside the JSON payload.
@MainActor
public final class WorkspaceArchiveService {
    /// Callback reporting the current stage and overall progress in `0...1`.
    public typealias ProgressHandler = (_ stage: String, _ fraction: Double) -> Void

    private let context: ModelContext
    private let repositories: RepositoryBundle
    private let galleryDirectory: URL
    private let appSupportDirectory: URL

    public init(
        context: ModelContext,
        repositories: RepositoryBundle,
        galleryDirectory: URL? = nil,
        appSupportDirectory: URL? = nil
    ) {
        self.context = context
        self.repositories = repositories
        self.galleryDirectory = galleryDirectory ?? GalleryStorageLocations.defaultGalleryDirectory()
        self.appSupportDirectory = appSupportDirectory ?? GalleryStorageLocations.defaultAppSupportDirectory()
    }

    /// Writes a zip archive of the current workspace to `url`.
    @discardableResult
    public func exportArchive(to url: URL, progress: ProgressHandler? = nil) throws -> WorkspaceExportSummary {
        progress?("Collecting records", 0.05)

        let payload = try collectPayload()
        var summary = WorkspaceExportSummary()
        summary.sessionCount = payload.sessions.count
        summary.messageCount = payload.messages.count
        summary.folderCount = payload.folders.count
        summary.documentCount = payload.documents.count
        summary.documentVersionCount = payload.documentVersions.count
        summary.noteCount = payload.notes.count
        summary.memoryCount = payload.memories.count
        summary.albumCount = payload.albums.count
        summary.imageCount = payload.images.count
        summary.comparisonCount = payload.comparisons.count
        summary.researchReportCount = payload.researchReports.count
        summary.taskCount = payload.tasks.count
        summary.agentTaskCount = payload.agentTasks.count
        summary.agentTaskEventCount = payload.agentTaskEvents.count
        summary.agentArtifactCount = payload.agentArtifacts.count

        progress?("Encoding archive", 0.35)
        let encoder = Self.makeEncoder()
        let manifest = WorkspaceArchive.Manifest()
        let manifestData = try encoder.encode(manifest)
        let payloadData = try encoder.encode(payload)

        var files: [String: Data] = [
            WorkspaceArchive.manifestFileName: manifestData,
            WorkspaceArchive.payloadFileName: payloadData,
        ]

        progress?("Packing files", 0.55)
        for image in payload.images {
            let source = galleryDirectory.appendingPathComponent(image.filename)
            if let data = try? Data(contentsOf: source) {
                files["\(WorkspaceArchive.galleryDirectoryName)/\(image.filename)"] = data
                summary.galleryFileCount += 1
            }
        }
        for task in payload.agentTasks {
            guard let fileName = task.contextFileName, !fileName.isEmpty else { continue }
            let source = AgentTaskContextStore.directory(appSupport: appSupportDirectory)
                .appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: source) {
                files["\(WorkspaceArchive.contextsDirectoryName)/\(fileName)"] = data
                summary.contextFileCount += 1
            }
        }

        progress?("Writing zip", 0.85)
        do {
            try ZipStore.zip(files: files, to: url)
        } catch {
            throw WorkspaceArchiveError.writeFailed(error.localizedDescription)
        }
        progress?("Complete", 1.0)
        return summary
    }

    /// Imports a zip (or a folder containing `payload.json`) into the current
    /// store. Security-scoped access is acquired for user-picked files.
    ///
    /// When `replaceExisting` is true, archive-covered records and their on-disk
    /// files are deleted first so the import becomes the new workspace. Email
    /// drafts and calendar events are never erased.
    @discardableResult
    public func importArchive(
        at url: URL,
        replaceExisting: Bool = false,
        progress: ProgressHandler? = nil
    ) throws -> WorkspaceArchiveCounts {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        progress?("Opening archive", 0.05)
        let prepared = try Self.openPackage(at: url)
        defer { prepared.cleanup() }

        let decoder = Self.makeDecoder()
        if let manifestURL = prepared.file(WorkspaceArchive.manifestFileName),
           let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? decoder.decode(WorkspaceArchive.Manifest.self, from: manifestData) {
            guard manifest.formatVersion <= WorkspaceArchive.formatVersion else {
                throw WorkspaceArchiveError.unsupportedVersion(manifest.formatVersion)
            }
        }

        guard let payloadURL = prepared.file(WorkspaceArchive.payloadFileName),
              let payloadData = try? Data(contentsOf: payloadURL) else {
            throw WorkspaceArchiveError.invalidArchive
        }

        let payload: WorkspaceArchive.Payload
        do {
            payload = try decoder.decode(WorkspaceArchive.Payload.self, from: payloadData)
        } catch {
            throw WorkspaceArchiveError.readFailed(error.localizedDescription)
        }

        var counts = WorkspaceArchiveCounts()

        if replaceExisting {
            counts.replacedExisting = true
            counts.replacedRecordCount = try eraseExistingWorkspaceContent(progress: progress)
        }

        progress?("Folders", 0.12)
        try importFolders(payload.folders, counts: &counts)

        progress?("Chats", 0.22)
        try importSessions(payload.sessions, counts: &counts)
        try importMessages(payload.messages, counts: &counts)

        progress?("Documents", 0.40)
        try importDocuments(payload.documents, counts: &counts)
        try importDocumentVersions(payload.documentVersions, counts: &counts)

        progress?("Notes", 0.55)
        try importNotes(payload.notes, counts: &counts)

        progress?("Memories", 0.62)
        try importMemories(payload.memories, counts: &counts)

        progress?("Gallery", 0.72)
        try importAlbums(payload.albums, counts: &counts)
        try importImages(payload.images, root: prepared.rootURL, counts: &counts)

        progress?("Research and tasks", 0.82)
        try importComparisons(payload.comparisons, counts: &counts)
        try importResearchReports(payload.researchReports, counts: &counts)
        try importTasks(payload.tasks, counts: &counts)

        progress?("Agent work", 0.90)
        try importAgentTasks(payload.agentTasks, root: prepared.rootURL, counts: &counts)
        try importAgentTaskEvents(payload.agentTaskEvents, counts: &counts)
        try importAgentArtifacts(payload.agentArtifacts, counts: &counts)

        try repositories.sessions.save()
        progress?("Complete", 1.0)
        return counts
    }

    // MARK: - Collect

    private func collectPayload() throws -> WorkspaceArchive.Payload {
        let sessions = try fetchAll(ChatSession.self)
        let messages = try fetchAll(ChatMessage.self)
        let folders = try fetchAll(Folder.self)
        let documents = try fetchAll(Document.self)
        let versions = try fetchAll(DocumentVersion.self)
        let notes = try fetchAll(Note.self)
        let memories = try fetchAll(Memory.self)
        let albums = try fetchAll(Album.self)
        let images = try fetchAll(GalleryImage.self)
        let comparisons = try fetchAll(Comparison.self)
        let reports = try fetchAll(ResearchReport.self)
        let tasks = try fetchAll(ScheduledTask.self)
        let agentTasks = try fetchAll(AgentTask.self)
        let events = try fetchAll(AgentTaskEvent.self)
        let artifacts = try fetchAll(AgentArtifact.self)

        return WorkspaceArchive.Payload(
            sessions: sessions.map(WorkspaceArchive.Session.init),
            messages: messages.map(WorkspaceArchive.Message.init),
            folders: folders.map(WorkspaceArchive.FolderRecord.init),
            documents: documents.map(WorkspaceArchive.DocumentRecord.init),
            documentVersions: versions.map(WorkspaceArchive.DocumentVersionRecord.init),
            notes: notes.map(WorkspaceArchive.NoteRecord.init),
            memories: memories.map(WorkspaceArchive.MemoryRecord.init),
            albums: albums.map(WorkspaceArchive.AlbumRecord.init),
            images: images.map(WorkspaceArchive.ImageRecord.init),
            comparisons: comparisons.map(WorkspaceArchive.ComparisonRecord.init),
            researchReports: reports.map(WorkspaceArchive.ResearchRecord.init),
            tasks: tasks.map(WorkspaceArchive.TaskRecord.init),
            agentTasks: agentTasks.map(WorkspaceArchive.AgentTaskRecord.init),
            agentTaskEvents: events.map(WorkspaceArchive.AgentTaskEventRecord.init),
            agentArtifacts: artifacts.map(WorkspaceArchive.AgentArtifactRecord.init)
        )
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    // MARK: - Replace

    /// Deletes archive-covered SwiftData records and their sidecar files so a
    /// subsequent import can occupy a clean workspace. Email drafts and calendar
    /// events are intentionally left in place.
    private func eraseExistingWorkspaceContent(progress: ProgressHandler?) throws -> Int {
        progress?("Erasing existing content", 0.08)
        var removed = 0
        // Children before parents where SwiftData does not cascade.
        removed += try deleteAll(AgentTaskEvent.self)
        removed += try deleteAll(AgentArtifact.self)
        removed += try deleteAll(ChatMessage.self)
        removed += try deleteAll(ChatSession.self)
        removed += try deleteAll(DocumentVersion.self)
        removed += try deleteAll(Document.self)
        removed += try deleteAll(Folder.self)
        removed += try deleteAll(Note.self)
        removed += try deleteAll(Memory.self)
        removed += try deleteAll(GalleryImage.self)
        removed += try deleteAll(Album.self)
        removed += try deleteAll(Comparison.self)
        removed += try deleteAll(ResearchReport.self)
        removed += try deleteAll(ScheduledTask.self)
        removed += try deleteAll(AgentTask.self)
        try context.save()
        clearDirectoryContents(galleryDirectory)
        clearDirectoryContents(AgentTaskContextStore.directory(appSupport: appSupportDirectory))
        return removed
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws -> Int {
        let items = try context.fetch(FetchDescriptor<T>())
        for item in items {
            context.delete(item)
        }
        return items.count
    }

    private func clearDirectoryContents(_ directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Import helpers

    private func importFolders(_ records: [WorkspaceArchive.FolderRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in topological(records, id: \.id, parentID: \.parentID) {
            if try repositories.folders.fetchFolder(id: record.id) != nil {
                counts.foldersSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.foldersImported += 1
        }
    }

    private func importSessions(_ records: [WorkspaceArchive.Session], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            if try repositories.sessions.fetchSession(id: record.id) != nil {
                counts.sessionsSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.sessionsImported += 1
        }
    }

    private func importMessages(_ records: [WorkspaceArchive.Message], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            guard let session = try repositories.sessions.fetchSession(id: record.sessionID) else {
                continue
            }
            if try messageExists(id: record.id) {
                counts.messagesSkipped += 1
                continue
            }
            let message = record.makeModel(session: session)
            context.insert(message)
            if session.messages == nil { session.messages = [] }
            session.messages?.append(message)
            counts.messagesImported += 1
        }
    }

    private func importDocuments(_ records: [WorkspaceArchive.DocumentRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            if try repositories.documents.fetchDocument(id: record.id) != nil {
                counts.documentsSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.documentsImported += 1
        }
    }

    private func importDocumentVersions(
        _ records: [WorkspaceArchive.DocumentVersionRecord],
        counts: inout WorkspaceArchiveCounts
    ) throws {
        for record in records {
            guard let document = try repositories.documents.fetchDocument(id: record.documentID) else {
                continue
            }
            if try documentVersionExists(id: record.id) {
                counts.documentVersionsSkipped += 1
                continue
            }
            let version = record.makeModel(document: document)
            context.insert(version)
            if document.versions == nil { document.versions = [] }
            document.versions?.append(version)
            counts.documentVersionsImported += 1
        }
    }

    private func importNotes(_ records: [WorkspaceArchive.NoteRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            if try repositories.notes.fetchNote(id: record.id) != nil {
                counts.notesSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.notesImported += 1
        }
    }

    private func importMemories(_ records: [WorkspaceArchive.MemoryRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            if try repositories.memories.fetchMemory(id: record.id) != nil {
                counts.memoriesSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.memoriesImported += 1
        }
    }

    private func importAlbums(_ records: [WorkspaceArchive.AlbumRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in records {
            if try repositories.gallery.fetchAlbum(id: record.id) != nil {
                counts.albumsSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.albumsImported += 1
        }
    }

    private func importImages(
        _ records: [WorkspaceArchive.ImageRecord],
        root: URL,
        counts: inout WorkspaceArchiveCounts
    ) throws {
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
        for record in records {
            if try repositories.gallery.fetchImage(id: record.id) != nil {
                counts.imagesSkipped += 1
                continue
            }
            guard try repositories.gallery.fetchAlbum(id: record.albumID) != nil else {
                continue
            }
            let source = root
                .appendingPathComponent(WorkspaceArchive.galleryDirectoryName)
                .appendingPathComponent(record.filename)
            let destination = galleryDirectory.appendingPathComponent(record.filename)
            if FileManager.default.fileExists(atPath: source.path),
               !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            context.insert(record.makeModel())
            counts.imagesImported += 1
        }
    }

    private func importComparisons(
        _ records: [WorkspaceArchive.ComparisonRecord],
        counts: inout WorkspaceArchiveCounts
    ) throws {
        for record in records {
            if try repositories.comparisons.fetchComparison(id: record.id) != nil {
                counts.comparisonsSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.comparisonsImported += 1
        }
    }

    private func importResearchReports(
        _ records: [WorkspaceArchive.ResearchRecord],
        counts: inout WorkspaceArchiveCounts
    ) throws {
        for record in records {
            if try repositories.researchReports.fetchReport(id: record.id) != nil {
                counts.researchReportsSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.researchReportsImported += 1
        }
    }

    private func importTasks(_ records: [WorkspaceArchive.TaskRecord], counts: inout WorkspaceArchiveCounts) throws {
        for record in topological(records, id: \.id, parentID: \.parentTaskID) {
            if try repositories.tasks.fetchTask(id: record.id) != nil {
                counts.tasksSkipped += 1
                continue
            }
            context.insert(record.makeModel())
            counts.tasksImported += 1
        }
    }

    private func importAgentTasks(
        _ records: [WorkspaceArchive.AgentTaskRecord],
        root: URL,
        counts: inout WorkspaceArchiveCounts
    ) throws {
        let contextDir = AgentTaskContextStore.directory(appSupport: appSupportDirectory)
        try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        for record in topological(records, id: \.id, parentID: \.parentTaskID) {
            if try repositories.agentTasks.fetchTask(id: record.id) != nil {
                counts.agentTasksSkipped += 1
                continue
            }
            if let fileName = record.contextFileName, !fileName.isEmpty {
                let source = root
                    .appendingPathComponent(WorkspaceArchive.contextsDirectoryName)
                    .appendingPathComponent(fileName)
                let destination = contextDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: source.path),
                   !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }
            context.insert(record.makeModel())
            counts.agentTasksImported += 1
        }
    }

    private func importAgentTaskEvents(
        _ records: [WorkspaceArchive.AgentTaskEventRecord],
        counts: inout WorkspaceArchiveCounts
    ) throws {
        for record in records {
            if try agentTaskEventExists(id: record.id) {
                counts.agentTaskEventsSkipped += 1
                continue
            }
            guard try repositories.agentTasks.fetchTask(id: record.taskID) != nil else {
                continue
            }
            context.insert(record.makeModel())
            counts.agentTaskEventsImported += 1
        }
    }

    private func importAgentArtifacts(
        _ records: [WorkspaceArchive.AgentArtifactRecord],
        counts: inout WorkspaceArchiveCounts
    ) throws {
        for record in records {
            if try repositories.agentArtifacts.fetchArtifact(id: record.id) != nil {
                counts.agentArtifactsSkipped += 1
                continue
            }
            guard try repositories.agentTasks.fetchTask(id: record.taskID) != nil else {
                continue
            }
            context.insert(record.makeModel())
            counts.agentArtifactsImported += 1
        }
    }

    private func messageExists(id: String) throws -> Bool {
        let descriptor = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first != nil
    }

    private func documentVersionExists(id: String) throws -> Bool {
        let descriptor = FetchDescriptor<DocumentVersion>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first != nil
    }

    private func agentTaskEventExists(id: String) throws -> Bool {
        let descriptor = FetchDescriptor<AgentTaskEvent>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first != nil
    }

    /// Parents before children; records whose parent is missing from the batch
    /// are emitted as-is (orphans stay parented to the original id).
    private func topological<T>(
        _ items: [T],
        id: KeyPath<T, String>,
        parentID: KeyPath<T, String?>
    ) -> [T] {
        var remaining = items
        var emitted: [T] = []
        var known = Set<String>()
        let ids = Set(items.map { $0[keyPath: id] })

        while !remaining.isEmpty {
            let ready = remaining.filter { item in
                guard let parent = item[keyPath: parentID] else { return true }
                return known.contains(parent) || !ids.contains(parent)
            }
            if ready.isEmpty {
                emitted.append(contentsOf: remaining)
                break
            }
            for item in ready {
                emitted.append(item)
                known.insert(item[keyPath: id])
            }
            remaining.removeAll { known.contains($0[keyPath: id]) }
        }
        return emitted
    }

    // MARK: - Package / JSON

    private struct OpenedPackage {
        let rootURL: URL
        let cleanup: () -> Void

        func file(_ name: String) -> URL? {
            let url = rootURL.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Resolves a user-selected zip, folder, or `payload.json` file to a readable root.
    private static func openPackage(at url: URL) throws -> OpenedPackage {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            throw WorkspaceArchiveError.invalidArchive
        }

        if isDirectory.boolValue {
            let root = resolvedRoot(in: url)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(WorkspaceArchive.payloadFileName).path) else {
                throw WorkspaceArchiveError.invalidArchive
            }
            return OpenedPackage(rootURL: root, cleanup: {})
        }

        if url.lastPathComponent == WorkspaceArchive.payloadFileName {
            return OpenedPackage(rootURL: url.deletingLastPathComponent(), cleanup: {})
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("anaiodyssey-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try ZipStore.unzip(url, to: destination)
        } catch let error as ZipStoreError {
            try? FileManager.default.removeItem(at: destination)
            throw WorkspaceArchiveError.readFailed(error.localizedDescription)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw WorkspaceArchiveError.invalidArchive
        }
        let root = resolvedRoot(in: destination)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(WorkspaceArchive.payloadFileName).path) else {
            try? FileManager.default.removeItem(at: destination)
            throw WorkspaceArchiveError.invalidArchive
        }
        return OpenedPackage(rootURL: root, cleanup: { try? FileManager.default.removeItem(at: destination) })
    }

    /// Unwraps a single enclosing folder when the zip contains one wrapper directory.
    private static func resolvedRoot(in url: URL) -> URL {
        let payload = url.appendingPathComponent(WorkspaceArchive.payloadFileName)
        if FileManager.default.fileExists(atPath: payload.path) {
            return url
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), children.count == 1,
              (try? children[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return url
        }
        let childPayload = children[0].appendingPathComponent(WorkspaceArchive.payloadFileName)
        if FileManager.default.fileExists(atPath: childPayload.path) {
            return children[0]
        }
        return url
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - DTO mapping

private extension WorkspaceArchive.Session {
    init(_ session: ChatSession) {
        self.init(
            id: session.id,
            name: session.name,
            endpointURL: session.endpointURL,
            model: session.model,
            owner: session.owner,
            rag: session.rag,
            archived: session.archived,
            folder: session.folder,
            headersJSON: session.headersJSON,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            lastAccessed: session.lastAccessed,
            lastMessageAt: session.lastMessageAt,
            isImportant: session.isImportant,
            messageCount: session.messageCount,
            totalInputTokens: session.totalInputTokens,
            totalOutputTokens: session.totalOutputTokens,
            mode: session.mode,
            crewMemberID: session.crewMemberID
        )
    }

    func makeModel() -> ChatSession {
        ChatSession(
            id: id,
            name: name,
            endpointURL: endpointURL,
            model: model,
            owner: owner,
            rag: rag,
            archived: archived,
            folder: folder,
            headersJSON: headersJSON,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAccessed: lastAccessed,
            lastMessageAt: lastMessageAt,
            isImportant: isImportant,
            messageCount: messageCount,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            mode: mode,
            crewMemberID: crewMemberID
        )
    }
}

private extension WorkspaceArchive.Message {
    init(_ message: ChatMessage) {
        self.init(
            id: message.id,
            sessionID: message.sessionID,
            role: message.role,
            content: message.content,
            metadata: message.metadata,
            timestamp: message.timestamp
        )
    }

    func makeModel(session: ChatSession) -> ChatMessage {
        ChatMessage(
            id: id,
            session: session,
            role: role,
            content: content,
            metadata: metadata,
            timestamp: timestamp
        )
    }
}

private extension WorkspaceArchive.FolderRecord {
    init(_ folder: Folder) {
        self.init(
            id: folder.id,
            name: folder.name,
            parentID: folder.parentID,
            kind: folder.kind,
            owner: folder.owner,
            sortOrder: folder.sortOrder,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt
        )
    }

    func makeModel() -> Folder {
        Folder(
            id: id,
            name: name,
            parentID: parentID,
            kind: FolderKind(rawValue: kind) ?? .documents,
            owner: owner,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension WorkspaceArchive.DocumentRecord {
    init(_ document: Document) {
        self.init(
            id: document.id,
            sessionID: document.sessionID,
            parentID: document.parentID,
            title: document.title,
            language: document.language,
            currentContent: document.currentContent,
            versionCount: document.versionCount,
            isActive: document.isActive,
            archived: document.archived,
            owner: document.owner,
            tidyVerdict: document.tidyVerdict,
            sourceEmailUID: document.sourceEmailUID,
            sourceEmailFolder: document.sourceEmailFolder,
            sourceEmailAccountID: document.sourceEmailAccountID,
            sourceEmailMessageID: document.sourceEmailMessageID,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        )
    }

    func makeModel() -> Document {
        Document(
            id: id,
            sessionID: sessionID,
            parentID: parentID,
            title: title,
            language: language,
            currentContent: currentContent,
            versionCount: versionCount,
            isActive: isActive,
            archived: archived,
            owner: owner,
            tidyVerdict: tidyVerdict,
            sourceEmailUID: sourceEmailUID,
            sourceEmailFolder: sourceEmailFolder,
            sourceEmailAccountID: sourceEmailAccountID,
            sourceEmailMessageID: sourceEmailMessageID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension WorkspaceArchive.DocumentVersionRecord {
    init(_ version: DocumentVersion) {
        self.init(
            id: version.id,
            documentID: version.documentID,
            versionNumber: version.versionNumber,
            content: version.content,
            summary: version.summary,
            source: version.source,
            createdAt: version.createdAt
        )
    }

    func makeModel(document: Document) -> DocumentVersion {
        DocumentVersion(
            id: id,
            document: document,
            versionNumber: versionNumber,
            content: content,
            summary: summary,
            source: source,
            createdAt: createdAt
        )
    }
}

private extension WorkspaceArchive.NoteRecord {
    init(_ note: Note) {
        self.init(
            id: note.id,
            owner: note.owner,
            parentID: note.parentID,
            title: note.title,
            content: note.content,
            checklistItems: note.checklistItems,
            noteType: note.noteType,
            color: note.color,
            label: note.label,
            pinned: note.pinned,
            archived: note.archived,
            dueDate: note.dueDate,
            source: note.source,
            sessionID: note.sessionID,
            sortOrder: note.sortOrder,
            imageURL: note.imageURL,
            repeatRule: note.repeatRule,
            aiClassification: note.aiClassification,
            aiContentHash: note.aiContentHash,
            agentSessionID: note.agentSessionID,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        )
    }

    func makeModel() -> Note {
        Note(
            id: id,
            owner: owner,
            parentID: parentID,
            title: title,
            content: content,
            checklistItems: checklistItems,
            noteType: noteType,
            color: color,
            label: label,
            pinned: pinned,
            archived: archived,
            dueDate: dueDate,
            source: source,
            sessionID: sessionID,
            sortOrder: sortOrder,
            imageURL: imageURL,
            repeatRule: repeatRule,
            aiClassification: aiClassification,
            aiContentHash: aiContentHash,
            agentSessionID: agentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension WorkspaceArchive.MemoryRecord {
    init(_ memory: Memory) {
        self.init(id: memory.id, text: memory.text, sessionID: memory.sessionID, createdAt: memory.createdAt)
    }

    func makeModel() -> Memory {
        Memory(id: id, text: text, sessionID: sessionID, createdAt: createdAt)
    }
}

private extension WorkspaceArchive.AlbumRecord {
    init(_ album: Album) {
        self.init(
            id: album.id,
            name: album.name,
            albumDescription: album.albumDescription,
            coverImageID: album.coverImageID
        )
    }

    func makeModel() -> Album {
        Album(id: id, name: name, albumDescription: albumDescription, coverImageID: coverImageID)
    }
}

private extension WorkspaceArchive.ImageRecord {
    init(_ image: GalleryImage) {
        self.init(
            id: image.id,
            albumID: image.albumID,
            filename: image.filename,
            caption: image.caption,
            createdAt: image.createdAt
        )
    }

    func makeModel() -> GalleryImage {
        GalleryImage(id: id, albumID: albumID, filename: filename, caption: caption, createdAt: createdAt)
    }
}

private extension WorkspaceArchive.ComparisonRecord {
    init(_ comparison: Comparison) {
        self.init(
            id: comparison.id,
            prompt: comparison.prompt,
            modelA: comparison.modelA,
            modelB: comparison.modelB,
            responseA: comparison.responseA,
            responseB: comparison.responseB,
            winner: comparison.winner,
            isBlind: comparison.isBlind,
            blindMappingJSON: comparison.blindMappingJSON,
            votedAt: comparison.votedAt
        )
    }

    func makeModel() -> Comparison {
        Comparison(
            id: id,
            prompt: prompt,
            modelA: modelA,
            modelB: modelB,
            responseA: responseA,
            responseB: responseB,
            winner: winner,
            isBlind: isBlind,
            blindMappingJSON: blindMappingJSON,
            votedAt: votedAt
        )
    }
}

private extension WorkspaceArchive.ResearchRecord {
    init(_ report: ResearchReport) {
        self.init(
            id: report.id,
            query: report.query,
            summary: report.summary,
            sourcesJSON: report.sourcesJSON,
            threadJSON: report.threadJSON,
            createdAt: report.createdAt
        )
    }

    func makeModel() -> ResearchReport {
        ResearchReport(
            id: id,
            query: query,
            summary: summary,
            sourcesJSON: sourcesJSON,
            threadJSON: threadJSON,
            createdAt: createdAt
        )
    }
}

private extension WorkspaceArchive.TaskRecord {
    init(_ task: ScheduledTask) {
        self.init(
            id: task.id,
            owner: task.owner,
            parentTaskID: task.parentTaskID,
            sortOrder: task.sortOrder,
            name: task.name,
            prompt: task.prompt,
            taskType: task.taskType,
            action: task.action,
            schedule: task.schedule,
            scheduledTime: task.scheduledTime,
            scheduledDay: task.scheduledDay,
            scheduledDate: task.scheduledDate,
            triggerType: task.triggerType,
            triggerEvent: task.triggerEvent,
            nextRun: task.nextRun,
            lastRun: task.lastRun,
            status: task.status,
            outputTarget: task.outputTarget,
            sessionID: task.sessionID,
            model: task.model,
            endpointURL: task.endpointURL,
            runCount: task.runCount,
            cronExpression: task.cronExpression,
            notificationsEnabled: task.notificationsEnabled,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
    }

    func makeModel() -> ScheduledTask {
        ScheduledTask(
            id: id,
            owner: owner,
            parentTaskID: parentTaskID,
            sortOrder: sortOrder,
            name: name,
            prompt: prompt,
            taskType: taskType,
            action: action,
            schedule: schedule,
            scheduledTime: scheduledTime,
            scheduledDay: scheduledDay,
            scheduledDate: scheduledDate,
            triggerType: triggerType,
            triggerEvent: triggerEvent,
            nextRun: nextRun,
            lastRun: lastRun,
            status: status,
            outputTarget: outputTarget,
            sessionID: sessionID,
            model: model,
            endpointURL: endpointURL,
            runCount: runCount,
            cronExpression: cronExpression,
            notificationsEnabled: notificationsEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension WorkspaceArchive.AgentTaskRecord {
    init(_ task: AgentTask) {
        self.init(
            id: task.id,
            title: task.title,
            assignment: task.assignment,
            status: task.status,
            assigneeAgentID: task.assigneeAgentID,
            controllerAgentID: task.controllerAgentID,
            handoffTarget: task.handoffTarget,
            contextInline: task.contextInline,
            contextFileName: task.contextFileName,
            parentTaskID: task.parentTaskID,
            sessionID: task.sessionID,
            priority: task.priority,
            resultSummary: task.resultSummary,
            currentAction: task.currentAction,
            changeLogJSON: task.changeLogJSON,
            conversationJSON: task.conversationJSON,
            errorMessage: task.errorMessage,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
    }

    func makeModel() -> AgentTask {
        AgentTask(
            id: id,
            title: title,
            assignment: assignment,
            status: AgentTaskStatus.migrateStored(status).rawValue,
            assigneeAgentID: assigneeAgentID,
            controllerAgentID: controllerAgentID,
            handoffTarget: handoffTarget,
            contextInline: contextInline,
            contextFileName: contextFileName,
            parentTaskID: parentTaskID,
            sessionID: sessionID,
            priority: priority,
            resultSummary: resultSummary,
            currentAction: currentAction,
            changeLogJSON: changeLogJSON,
            conversationJSON: conversationJSON,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension WorkspaceArchive.AgentTaskEventRecord {
    init(_ event: AgentTaskEvent) {
        self.init(
            id: event.id,
            taskID: event.taskID,
            actorType: event.actorType,
            actorID: event.actorID,
            action: event.action,
            message: event.message,
            createdAt: event.createdAt
        )
    }

    func makeModel() -> AgentTaskEvent {
        AgentTaskEvent(
            id: id,
            taskID: taskID,
            actorType: actorType,
            actorID: actorID,
            action: action,
            message: message,
            createdAt: createdAt
        )
    }
}

private extension WorkspaceArchive.AgentArtifactRecord {
    init(_ artifact: AgentArtifact) {
        self.init(
            id: artifact.id,
            taskID: artifact.taskID,
            kind: artifact.kind,
            title: artifact.title,
            body: artifact.body,
            linkedEntityID: artifact.linkedEntityID,
            createdAt: artifact.createdAt,
            updatedAt: artifact.updatedAt
        )
    }

    func makeModel() -> AgentArtifact {
        AgentArtifact(
            id: id,
            taskID: taskID,
            kind: kind,
            title: title,
            body: body,
            linkedEntityID: linkedEntityID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
