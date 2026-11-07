// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `DocumentRepositoryProtocol`.
///
/// Beyond plain CRUD, this tracks editor "tab" ordering. SwiftData has no
/// natural ordering for the open documents, so the order is kept in an in-memory
/// `openTabOrder` array (seeded from the persisted `isActive` flags at init).
@MainActor
public final class SwiftDataDocumentRepository: DocumentRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext
    /// Document IDs in left-to-right tab order; the authoritative tab ordering.
    private var openTabOrder: [String] = []

    /// Binds to a context and rebuilds the tab order from the persisted state.
    public init(context: ModelContext) {
        self.context = context
        restoreOpenTabOrder()
    }

    /// Seeds `openTabOrder` from documents currently marked active, ordered by
    /// `updatedAt` as a best-effort reconstruction of the prior tab order.
    private func restoreOpenTabOrder() {
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.isActive && !$0.archived },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        openTabOrder = (try? context.fetch(descriptor).map(\.id)) ?? []
    }

    @discardableResult
    public func createDocument(title: String, content: String = "") throws -> Document {
        try createDocument(title: title, content: content, parentID: nil)
    }

    @discardableResult
    public func createDocument(title: String, content: String, parentID: String?) throws -> Document {
        // New documents start closed (not an open tab) until explicitly opened.
        let document = Document(parentID: parentID, title: title, currentContent: content, isActive: false)
        context.insert(document)
        try save()
        return document
    }

    public func listDocuments(inFolder folderID: String?) throws -> [Document] {
        // SwiftData `#Predicate` can't compare an optional field to a variable
        // optional, so branch on root (nil) vs. a specific folder id.
        let descriptor: FetchDescriptor<Document>
        if let folderID {
            descriptor = FetchDescriptor<Document>(
                predicate: #Predicate { !$0.archived && $0.parentID == folderID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<Document>(
                predicate: #Predicate { !$0.archived && $0.parentID == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func moveDocument(id: String, toFolderID folderID: String?) throws {
        guard let document = try fetchDocument(id: id) else {
            throw RepositoryError.notFound(id)
        }
        document.parentID = folderID
        document.updatedAt = .now
        try save()
    }

    public func fetchDocument(id: String) throws -> Document? {
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listLibraryDocuments() throws -> [Document] {
        // Reuse the shared "active (non-archived) documents" query.
        try context.fetch(DocumentFetch.activeDocuments())
    }

    public func openTab(documentID: String) throws {
        guard let document = try fetchDocument(id: documentID) else {
            throw RepositoryError.notFound(documentID)
        }
        // Mark active and move the tab to the end (most-recently-opened position),
        // de-duplicating first so re-opening just re-orders.
        document.isActive = true
        document.updatedAt = .now
        openTabOrder.removeAll { $0 == documentID }
        openTabOrder.append(documentID)
        try save()
    }

    public func closeTab(documentID: String) throws {
        guard let document = try fetchDocument(id: documentID) else {
            throw RepositoryError.notFound(documentID)
        }
        // Clear the active flag and drop it from the ordering.
        document.isActive = false
        openTabOrder.removeAll { $0 == documentID }
        try save()
    }

    public func listOpenTabs() throws -> [Document] {
        // Fetch the active documents, then re-impose `openTabOrder` on top of the
        // unordered query result.
        let openIDs = Set(openTabOrder)
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { document in
                document.isActive && !document.archived
            }
        )
        let documents = try context.fetch(descriptor)
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        // First, the tabs we have a known order for...
        var ordered: [Document] = []
        for id in openTabOrder where openIDs.contains(id) {
            if let document = byID[id] {
                ordered.append(document)
            }
        }
        // ...then any active documents we didn't have ordering info for (e.g.
        // opened in another context) appended at the end.
        for document in documents where !openTabOrder.contains(document.id) {
            ordered.append(document)
        }
        return ordered
    }

    public func updateDocument(id: String, title: String?, content: String?) throws {
        guard let document = try fetchDocument(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Partial update: only overwrite fields that were supplied.
        if let title {
            document.title = title
        }
        if let content {
            document.currentContent = content
        }
        document.updatedAt = .now
        try save()
    }

    public func deleteDocument(id: String) throws {
        guard let document = try fetchDocument(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Drop any tab tracking before removing the record (versions cascade).
        openTabOrder.removeAll { $0 == id }
        context.delete(document)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
