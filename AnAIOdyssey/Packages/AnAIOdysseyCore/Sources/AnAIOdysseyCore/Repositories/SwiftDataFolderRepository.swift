// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `FolderRepositoryProtocol`.
///
/// Folders form a per-`kind` tree via `parentID`. Deleting a folder reparents its
/// direct children (subfolders, documents, notes) up to the deleted folder's
/// parent so nothing is lost. Moves guard against introducing cycles.
@MainActor
public final class SwiftDataFolderRepository: FolderRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createFolder(name: String, kind: FolderKind, parentID: String?) throws -> Folder {
        let folder = Folder(name: name, parentID: parentID, kind: kind)
        context.insert(folder)
        try save()
        return folder
    }

    public func fetchFolder(id: String) throws -> Folder? {
        let descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    public func listFolders(kind: FolderKind, parent parentID: String?) throws -> [Folder] {
        let kindRaw = kind.rawValue
        // Branch on root (nil) vs. a specific parent id — `#Predicate` can't
        // compare an optional field to a variable optional.
        let descriptor: FetchDescriptor<Folder>
        if let parentID {
            descriptor = FetchDescriptor<Folder>(
                predicate: #Predicate { $0.kind == kindRaw && $0.parentID == parentID },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        } else {
            descriptor = FetchDescriptor<Folder>(
                predicate: #Predicate { $0.kind == kindRaw && $0.parentID == nil },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func listAllFolders(kind: FolderKind) throws -> [Folder] {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.kind == kindRaw },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    public func renameFolder(id: String, name: String) throws {
        guard let folder = try fetchFolder(id: id) else {
            throw RepositoryError.notFound(id)
        }
        folder.name = name
        folder.updatedAt = .now
        try save()
    }

    public func moveFolder(id: String, newParentID: String?) throws {
        guard let folder = try fetchFolder(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // No-op if unchanged; reject moves into the folder itself.
        guard newParentID != id else { return }
        // Reject moving a folder into one of its own descendants (a cycle).
        if let newParentID, try isDescendant(candidateID: newParentID, ofFolderID: id) {
            return
        }
        folder.parentID = newParentID
        folder.updatedAt = .now
        try save()
    }

    public func deleteFolder(id: String) throws {
        guard let folder = try fetchFolder(id: id) else {
            throw RepositoryError.notFound(id)
        }
        let newParent = folder.parentID
        let kindRaw = folder.kind

        // Reparent direct child folders up to this folder's parent.
        let childFolders = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.kind == kindRaw && $0.parentID == id }
        )
        for child in try context.fetch(childFolders) {
            child.parentID = newParent
            child.updatedAt = .now
        }

        // Reparent contained documents/notes (whichever tree this folder is in).
        switch folder.folderKind {
        case .documents:
            let docs = FetchDescriptor<Document>(predicate: #Predicate { $0.parentID == id })
            for doc in try context.fetch(docs) {
                doc.parentID = newParent
                doc.updatedAt = .now
            }
        case .notes:
            let notes = FetchDescriptor<Note>(predicate: #Predicate { $0.parentID == id })
            for note in try context.fetch(notes) {
                note.parentID = newParent
                note.updatedAt = .now
            }
        }

        context.delete(folder)
        try save()
    }

    public func save() throws {
        try context.save()
    }

    /// Whether `candidateID` is `folderID` itself or lives somewhere beneath it,
    /// used to reject cyclic moves. Walks up from the candidate to a root.
    private func isDescendant(candidateID: String, ofFolderID folderID: String) throws -> Bool {
        var currentID: String? = candidateID
        var guardCount = 0
        while let id = currentID, guardCount < 1000 {
            if id == folderID { return true }
            currentID = try fetchFolder(id: id)?.parentID
            guardCount += 1
        }
        return false
    }
}
