// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A single long-term "memory" — a piece of text the assistant should be able
/// to recall semantically later.
///
/// The canonical record lives here in SwiftData, while its embedding vector is
/// stored separately in the SQLite-backed `VectorIndexStore`. `MemoryService`
/// keeps the two in sync (creating, searching, and deleting across both).
@Model
public final class Memory {
    /// Stable identifier (UUID string); also the key linking this record to its
    /// embedding row in the vector index.
    public var id: String = ""
    /// The remembered content itself.
    public var text: String = ""
    /// Optional originating chat session, for provenance/filtering.
    public var sessionID: String?
    /// Creation timestamp, used to list memories newest-first.
    public var createdAt: Date = Date()

    /// Creates a memory; `id` defaults to a fresh UUID.
    public init(
        id: String = UUID().uuidString,
        text: String,
        sessionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}
