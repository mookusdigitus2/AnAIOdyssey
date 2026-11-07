// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `NoteRepositoryProtocol`.
@MainActor
public final class SwiftDataNoteRepository: NoteRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createNote(title: String, content: String? = nil) throws -> Note {
        try createNote(title: title, content: content, parentID: nil)
    }

    @discardableResult
    public func createNote(title: String, content: String?, parentID: String?) throws -> Note {
        let note = Note(parentID: parentID, title: title, content: content)
        context.insert(note)
        try save()
        return note
    }

    public func listNotes(inFolder folderID: String?, includeArchived: Bool = false) throws -> [Note] {
        // Branch on the (optional) folder and archived filters; SwiftData can't
        // compare an optional field to a variable optional inside `#Predicate`.
        let descriptor: FetchDescriptor<Note>
        switch (folderID, includeArchived) {
        case let (folderID?, false):
            descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { !$0.archived && $0.parentID == folderID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        case let (folderID?, true):
            descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { $0.parentID == folderID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        case (nil, false):
            descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { !$0.archived && $0.parentID == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        case (nil, true):
            descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { $0.parentID == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
        // Float pinned notes to the top while keeping newest-first within groups.
        let notes = try context.fetch(descriptor)
        return notes.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func moveNote(id: String, toFolderID folderID: String?) throws {
        guard let note = try fetchNote(id: id) else {
            throw RepositoryError.notFound(id)
        }
        note.parentID = folderID
        note.updatedAt = .now
        try save()
    }

    public func fetchNote(id: String) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listVisibleNotes(includeArchived: Bool = false) throws -> [Note] {
        // Choose the fetch with or without the archived filter.
        let descriptor: FetchDescriptor<Note>
        if includeArchived {
            descriptor = FetchDescriptor<Note>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { note in
                    !note.archived
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
        // Re-sort in memory to float pinned notes to the top while keeping the
        // newest-first order within each group (SwiftData can't express the
        // composite pinned-then-date sort directly here).
        let notes = try context.fetch(descriptor)
        return notes.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func setPinned(id: String, pinned: Bool) throws {
        guard let note = try fetchNote(id: id) else {
            throw RepositoryError.notFound(id)
        }
        note.pinned = pinned
        note.updatedAt = .now
        try save()
    }

    public func setArchived(id: String, archived: Bool) throws {
        guard let note = try fetchNote(id: id) else {
            throw RepositoryError.notFound(id)
        }
        note.archived = archived
        note.updatedAt = .now
        try save()
    }

    public func updateNote(
        id: String,
        title: String?,
        content: String?,
        checklistItems: [ChecklistItem]?
    ) throws {
        guard let note = try fetchNote(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Partial update: only overwrite fields that were supplied.
        if let title {
            note.title = title
        }
        if let content {
            note.content = content
        }
        if let checklistItems {
            note.checklistItems = checklistItems
        }
        note.updatedAt = .now
        try save()
    }

    public func deleteNote(id: String) throws {
        guard let note = try fetchNote(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(note)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
