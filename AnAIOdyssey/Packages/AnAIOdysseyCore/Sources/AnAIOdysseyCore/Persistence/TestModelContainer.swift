// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// In-memory SwiftData container for unit tests.
///
/// `@MainActor` because `ModelContext` work in this app is main-actor bound;
/// each call yields a fresh, disk-free store for isolated test runs.
@MainActor
public enum TestModelContainer {
    /// Builds a fresh in-memory container using the shared app schema.
    public static func make() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: AnAIOdysseySchema.schema, configurations: configuration)
    }
}

/// Reusable `FetchDescriptor` builders for documents.
///
/// Keeping these queries here (rather than inline at call sites) lets
/// repositories and tests share the exact same predicate and sort order.
public enum DocumentFetch {
    /// Non-archived documents, most-recently-updated first — the "library" view.
    public static func activeDocuments() -> FetchDescriptor<Document> {
        FetchDescriptor<Document>(
            predicate: #Predicate { document in
                !document.archived
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }
}

/// Reusable `FetchDescriptor` builders for chat messages.
public enum ChatMessageFetch {
    /// All messages for a session in chronological (oldest-first) order.
    public static func messages(for sessionID: String) -> FetchDescriptor<ChatMessage> {
        FetchDescriptor<ChatMessage>(
            predicate: #Predicate { message in
                message.sessionID == sessionID
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
    }
}
