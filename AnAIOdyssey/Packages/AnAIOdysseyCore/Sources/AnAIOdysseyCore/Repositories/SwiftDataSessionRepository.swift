// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `SessionRepositoryProtocol`.
@MainActor
public final class SwiftDataSessionRepository: SessionRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createSession(
        name: String,
        endpointURL: String,
        model: String,
        owner: String? = nil
    ) throws -> ChatSession {
        let session = ChatSession(
            name: name,
            endpointURL: endpointURL,
            model: model,
            owner: owner
        )
        context.insert(session)
        try save()
        return session
    }

    public func fetchSession(id: String) throws -> ChatSession? {
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func renameSession(id: String, name: String) throws {
        guard let session = try fetchSession(id: id) else {
            throw RepositoryError.notFound(id)
        }
        session.name = name
        session.updatedAt = .now
        try save()
    }

    public func listActiveSessions() throws -> [ChatSession] {
        // Exclude archived sessions and surface the most recently active first
        // (falling back to `updatedAt` when a session has no messages yet).
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { session in
                !session.archived
            },
            sortBy: [
                SortDescriptor(\.lastMessageAt, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse),
            ]
        )
        return try context.fetch(descriptor)
    }

    public func addMessage(sessionID: String, role: String, content: String) throws -> ChatMessage {
        guard let session = try fetchSession(id: sessionID) else {
            throw RepositoryError.notFound(sessionID)
        }
        // Delegate to the model so cached counters/timestamps stay authoritative,
        // then persist.
        let message = session.addMessage(role: role, content: content)
        try save()
        return message
    }

    public func messages(for sessionID: String) throws -> [ChatMessage] {
        // Reuse the shared chronological fetch descriptor.
        try context.fetch(ChatMessageFetch.messages(for: sessionID))
    }

    public func deleteSession(id: String) throws {
        guard let session = try fetchSession(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(session)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
