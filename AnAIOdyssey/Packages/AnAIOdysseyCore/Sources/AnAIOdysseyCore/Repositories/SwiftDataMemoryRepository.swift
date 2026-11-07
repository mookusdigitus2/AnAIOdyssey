// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Persistence interface for `Memory` records (the record half of long-term
/// memory; embeddings live in `VectorIndexStore`).
@MainActor
public protocol MemoryRepositoryProtocol: AnyObject {
    /// Creates and persists a memory, returning it.
    @discardableResult
    func createMemory(text: String, sessionID: String?) throws -> Memory

    /// Looks up a memory by id, or `nil` if absent.
    func fetchMemory(id: String) throws -> Memory?
    /// All memories, newest first.
    func listMemories() throws -> [Memory]
    /// Deletes a memory record.
    func deleteMemory(id: String) throws
    /// Flushes pending changes to the store.
    func save() throws
}

/// SwiftData-backed implementation of `MemoryRepositoryProtocol`.
@MainActor
public final class SwiftDataMemoryRepository: MemoryRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext` (usually shared via
    /// `RepositoryBundle`).
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createMemory(text: String, sessionID: String? = nil) throws -> Memory {
        // Insert the new record and persist immediately so callers can rely on it
        // being durable on return.
        let memory = Memory(text: text, sessionID: sessionID)
        context.insert(memory)
        try save()
        return memory
    }

    public func fetchMemory(id: String) throws -> Memory? {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listMemories() throws -> [Memory] {
        // Newest-first ordering for the memory list UI.
        let descriptor = FetchDescriptor<Memory>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    public func deleteMemory(id: String) throws {
        // Resolve before deleting so a missing id is a clear `notFound` error.
        guard let memory = try fetchMemory(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(memory)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
