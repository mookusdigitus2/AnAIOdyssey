// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Common error type for all repositories.
public enum RepositoryError: Error, Equatable {
    /// No record matched the given identifier (carried as the payload).
    case notFound(String)
}

/// Persistence interface for chat sessions and their messages.
///
/// Abstracting over SwiftData lets call sites and tests depend on behaviour
/// rather than the concrete store. `@MainActor` because the backing
/// `ModelContext` is main-actor bound. All methods `throw` to surface store
/// errors and `RepositoryError.notFound`.
@MainActor
public protocol SessionRepositoryProtocol: AnyObject {
    /// Creates and persists a new chat session, returning it.
    @discardableResult
    func createSession(
        name: String,
        endpointURL: String,
        model: String,
        owner: String?
    ) throws -> ChatSession

    /// Looks up a session by id, or `nil` if absent.
    func fetchSession(id: String) throws -> ChatSession?
    /// Renames a session; throws `notFound` if the id is unknown.
    func renameSession(id: String, name: String) throws
    /// Non-archived sessions, ordered by recent activity.
    func listActiveSessions() throws -> [ChatSession]
    /// Appends a message to a session and persists it.
    func addMessage(sessionID: String, role: String, content: String) throws -> ChatMessage
    /// All messages for a session in chronological order.
    func messages(for sessionID: String) throws -> [ChatMessage]
    /// Deletes a session (and, via cascade, its messages).
    func deleteSession(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for documents, including editor "tab" state.
@MainActor
public protocol DocumentRepositoryProtocol: AnyObject {
    /// Creates a document (initially closed, i.e. not an open tab).
    @discardableResult
    func createDocument(title: String, content: String) throws -> Document

    /// Creates a document inside the given folder (`nil` = root of the tree).
    @discardableResult
    func createDocument(title: String, content: String, parentID: String?) throws -> Document

    /// Looks up a document by id, or `nil` if absent.
    func fetchDocument(id: String) throws -> Document?
    /// Non-archived documents for the library view.
    func listLibraryDocuments() throws -> [Document]
    /// Non-archived documents directly inside `folderID` (`nil` = root).
    func listDocuments(inFolder folderID: String?) throws -> [Document]
    /// Moves a document into a folder (`nil` = root of the tree).
    func moveDocument(id: String, toFolderID folderID: String?) throws
    /// Marks a document as an open tab.
    func openTab(documentID: String) throws
    /// Marks a document as closed (no longer a tab).
    func closeTab(documentID: String) throws
    /// Open documents in tab order.
    func listOpenTabs() throws -> [Document]
    /// Updates title and/or content (nil fields are left unchanged).
    func updateDocument(id: String, title: String?, content: String?) throws
    /// Deletes a document and its versions.
    func deleteDocument(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for notes and checklists.
@MainActor
public protocol NoteRepositoryProtocol: AnyObject {
    /// Creates a note, returning it.
    @discardableResult
    func createNote(title: String, content: String?) throws -> Note

    /// Creates a note inside the given folder (`nil` = root of the tree).
    @discardableResult
    func createNote(title: String, content: String?, parentID: String?) throws -> Note

    /// Looks up a note by id, or `nil` if absent.
    func fetchNote(id: String) throws -> Note?
    /// Visible notes (pinned first), optionally including archived ones.
    func listVisibleNotes(includeArchived: Bool) throws -> [Note]
    /// Visible notes directly inside `folderID` (`nil` = root), pinned first.
    func listNotes(inFolder folderID: String?, includeArchived: Bool) throws -> [Note]
    /// Moves a note into a folder (`nil` = root of the tree).
    func moveNote(id: String, toFolderID folderID: String?) throws
    /// Pins or unpins a note.
    func setPinned(id: String, pinned: Bool) throws
    /// Archives or unarchives a note.
    func setArchived(id: String, archived: Bool) throws
    /// Updates title/content/checklist (nil fields are left unchanged).
    func updateNote(id: String, title: String?, content: String?, checklistItems: [ChecklistItem]?) throws
    /// Deletes a note.
    func deleteNote(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for scheduled tasks (storage only; scheduling lives in
/// `TaskSchedulerService`).
@MainActor
public protocol TaskRepositoryProtocol: AnyObject {
    /// Creates and persists a scheduled task, returning it.
    @discardableResult
    func createTask(
        name: String,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        sessionID: String?
    ) throws -> ScheduledTask

    /// Creates a task nested under `parentTaskID` (`nil` = top-level).
    @discardableResult
    func createTask(
        name: String,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        sessionID: String?,
        parentTaskID: String?
    ) throws -> ScheduledTask

    /// Looks up a task by id, or `nil` if absent.
    func fetchTask(id: String) throws -> ScheduledTask?
    /// Lists tasks, optionally filtered by status, ordered by next run.
    func listTasks(status: String?) throws -> [ScheduledTask]
    /// Direct subtasks of `parentTaskID` (or top-level tasks when `nil`).
    func listSubtasks(parentTaskID: String?, status: String?) throws -> [ScheduledTask]
    /// Updates the given fields of a task (nil fields are left unchanged).
    func updateTask(
        id: String,
        name: String?,
        prompt: String?,
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        status: String?,
        nextRun: Date?
    ) throws
    /// Deletes a task.
    func deleteTask(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for composed-but-unsent email drafts.
///
/// The assistant creates drafts here (it cannot send mail); the Email workspace
/// lists them for the user to review, edit, and send manually.
@MainActor
public protocol EmailDraftRepositoryProtocol: AnyObject {
    /// Creates and persists a draft, returning it.
    @discardableResult
    func createDraft(
        mode: String,
        toRecipients: String,
        ccRecipients: String,
        subject: String,
        body: String,
        originalMessageID: String?,
        originalSubject: String?,
        accountID: String?,
        source: String,
        sessionID: String?
    ) throws -> EmailDraft

    /// Looks up a draft by id, or `nil` if absent.
    func fetchDraft(id: String) throws -> EmailDraft?
    /// All drafts, most recently updated first.
    func listDrafts() throws -> [EmailDraft]
    /// Updates editable fields of a draft (nil fields are left unchanged).
    func updateDraft(
        id: String,
        toRecipients: String?,
        ccRecipients: String?,
        subject: String?,
        body: String?
    ) throws
    /// Deletes a draft.
    func deleteDraft(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for the local calendar-event cache.
@MainActor
public protocol CalendarEventRepositoryProtocol: AnyObject {
    /// Inserts or updates a cached event keyed by `id` (the EventKit identifier).
    @discardableResult
    func upsertEvent(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarID: String,
        notes: String?,
        location: String?,
        allDay: Bool,
        status: String
    ) throws -> CalendarEventRecord

    /// Looks up a cached event by id, or `nil` if absent.
    func fetchEvent(id: String) throws -> CalendarEventRecord?
    /// Cached events overlapping the `[start, end]` window (cancelled excluded).
    func listEvents(from start: Date, to end: Date) throws -> [CalendarEventRecord]
    /// Removes an event from the cache.
    func deleteEvent(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for gallery albums and images, including the on-disk
/// image files.
@MainActor
public protocol GalleryRepositoryProtocol: AnyObject {
    /// Creates an album, returning it.
    @discardableResult
    func createAlbum(name: String, description: String?) throws -> Album

    /// Looks up an album by id, or `nil` if absent.
    func fetchAlbum(id: String) throws -> Album?
    /// All albums, alphabetically by name.
    func listAlbums() throws -> [Album]
    /// Updates album fields (nil fields are left unchanged).
    func updateAlbum(id: String, name: String?, description: String?, coverImageID: String?) throws
    /// Deletes an album along with its images and their files.
    func deleteAlbum(id: String) throws

    /// Writes image bytes to disk and creates the matching metadata record.
    @discardableResult
    func importImage(
        albumID: String,
        data: Data,
        suggestedFilename: String?,
        caption: String?
    ) throws -> GalleryImage

    /// Looks up an image record by id, or `nil` if absent.
    func fetchImage(id: String) throws -> GalleryImage?
    /// Images in an album, newest first.
    func listImages(albumID: String) throws -> [GalleryImage]
    /// Updates (or clears) an image's caption.
    func updateImageCaption(id: String, caption: String?) throws
    /// Deletes an image record and its on-disk file.
    func deleteImage(id: String) throws
    /// Resolves the on-disk file URL for an image record.
    func imageFileURL(for image: GalleryImage) -> URL
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for model A/B comparisons and their votes.
@MainActor
public protocol ComparisonRepositoryProtocol: AnyObject {
    /// Creates a comparison, returning it.
    @discardableResult
    func createComparison(
        prompt: String,
        modelA: String,
        modelB: String,
        responseA: String?,
        responseB: String?,
        isBlind: Bool,
        blindMappingJSON: String?,
        resultsJSON: String?
    ) throws -> Comparison

    /// Looks up a comparison by id, or `nil` if absent.
    func fetchComparison(id: String) throws -> Comparison?
    /// All comparisons, voted ones first (most recent vote first).
    func listComparisons() throws -> [Comparison]
    /// Updates responses/winner/vote-time (nil fields are left unchanged).
    func updateComparison(
        id: String,
        responseA: String?,
        responseB: String?,
        winner: String?,
        votedAt: Date?
    ) throws
    /// Records a winner and stamps the vote time to now.
    func recordVote(id: String, winner: String) throws
    /// Deletes a comparison.
    func deleteComparison(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

extension ComparisonRepositoryProtocol {
    /// Creates a comparison without multi-model results JSON.
    @discardableResult
    public func createComparison(
        prompt: String,
        modelA: String,
        modelB: String,
        responseA: String?,
        responseB: String?,
        isBlind: Bool,
        blindMappingJSON: String?
    ) throws -> Comparison {
        try createComparison(
            prompt: prompt,
            modelA: modelA,
            modelB: modelB,
            responseA: responseA,
            responseB: responseB,
            isBlind: isBlind,
            blindMappingJSON: blindMappingJSON,
            resultsJSON: nil
        )
    }
}

/// Persistence interface for saved research reports.
@MainActor
public protocol ResearchReportRepositoryProtocol: AnyObject {
    /// Creates a report, returning it.
    @discardableResult
    func createReport(
        query: String,
        summary: String,
        sourcesJSON: String,
        threadJSON: String
    ) throws -> ResearchReport

    /// Looks up a report by id, or `nil` if absent.
    func fetchReport(id: String) throws -> ResearchReport?
    /// All reports, newest first.
    func listReports() throws -> [ResearchReport]
    /// Updates summary/thread and optionally sources (nil source is unchanged).
    func updateReport(
        id: String,
        summary: String,
        threadJSON: String,
        sourcesJSON: String?
    ) throws
    /// Deletes a report.
    func deleteReport(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// Persistence interface for the nestable folder tree backing Documents & Notes.
@MainActor
public protocol FolderRepositoryProtocol: AnyObject {
    /// Creates a folder in the given tree under `parentID` (`nil` = root).
    @discardableResult
    func createFolder(name: String, kind: FolderKind, parentID: String?) throws -> Folder

    /// Looks up a folder by id, or `nil` if absent.
    func fetchFolder(id: String) throws -> Folder?
    /// Direct child folders of `parentID` (or roots when `nil`) in a tree.
    func listFolders(kind: FolderKind, parent parentID: String?) throws -> [Folder]
    /// Every folder in a tree (any depth), for building a full hierarchy.
    func listAllFolders(kind: FolderKind) throws -> [Folder]
    /// Renames a folder; throws `notFound` if the id is unknown.
    func renameFolder(id: String, name: String) throws
    /// Moves a folder under a new parent (`nil` = root); rejects cycles.
    func moveFolder(id: String, newParentID: String?) throws
    /// Deletes a folder, reparenting its direct children to the folder's parent.
    func deleteFolder(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}
