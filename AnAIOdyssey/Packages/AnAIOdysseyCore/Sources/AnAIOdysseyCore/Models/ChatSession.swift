// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// The interaction style of a `ChatSession` — mirrors Python `Session.mode`.
/// Stored as the raw `mode` string.
public enum ChatSessionMode: String, Codable, Sendable {
    /// Plain conversational chat.
    case chat
    /// Tool-using autonomous agent.
    case agent
    /// Deep-research workflow.
    case research
}

/// A conversation thread with a model endpoint, plus its configuration and
/// running statistics.
///
/// Owns its `ChatMessage`s via a cascade relationship and caches aggregate
/// counters (message/token counts, last-activity timestamps) so list views can
/// sort and summarize without scanning every message.
@Model
public final class ChatSession {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// User-facing session name.
    public var name: String = ""
    /// Model endpoint URL and model identifier this session talks to.
    public var endpointURL: String = ""
    public var model: String = ""
    /// Optional owning user.
    public var owner: String?

    /// Whether retrieval-augmented generation is enabled for this session.
    public var rag: Bool = false
    /// Whether the session is archived (hidden from active lists).
    public var archived: Bool = false
    /// Optional folder/grouping label.
    public var folder: String?

    /// JSON-encoded request headers for the model endpoint.
    public var headersJSON: String = "{}"

    /// Lifecycle and activity timestamps. `lastMessageAt` (falling back to
    /// `updatedAt`) drives the recency sort in session lists.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var lastAccessed: Date = Date()
    public var lastMessageAt: Date?

    /// User "pin"/important flag.
    public var isImportant: Bool = false
    /// Cached aggregate counters kept in sync as messages are added, so the UI
    /// can show totals without loading every message.
    public var messageCount: Int = 0
    public var totalInputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    /// Optional `ChatSessionMode` raw value.
    public var mode: String?
    /// Optional "crew member"/persona identifier driving this session.
    public var crewMemberID: String?

    /// All messages in the session. Cascade delete removes them with the
    /// session; optional because SwiftData faults relationships lazily.
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    public var messages: [ChatMessage]? = []

    /// Creates a session; `id` defaults to a fresh UUID.
    public init(
        id: String = UUID().uuidString,
        name: String,
        endpointURL: String,
        model: String,
        owner: String? = nil,
        rag: Bool = false,
        archived: Bool = false,
        folder: String? = nil,
        headersJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessed: Date = Date(),
        lastMessageAt: Date? = nil,
        isImportant: Bool = false,
        messageCount: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        mode: String? = nil,
        crewMemberID: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.model = model
        self.owner = owner
        self.rag = rag
        self.archived = archived
        self.folder = folder
        self.headersJSON = headersJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessed = lastAccessed
        self.lastMessageAt = lastMessageAt
        self.isImportant = isImportant
        self.messageCount = messageCount
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.mode = mode
        self.crewMemberID = crewMemberID
        self.messages = messages
    }

    /// A session is "active" as long as it hasn't been archived.
    public var isActive: Bool { !archived }

    /// Appends a new message to the session and updates the cached counters and
    /// activity timestamps so derived state stays consistent.
    ///
    /// Centralizing message creation here keeps `messageCount`/`lastMessageAt`
    /// authoritative. Returns the created `ChatMessage` for the caller to persist
    /// or inspect.
    public func addMessage(role: String, content: String, metadata: String? = nil) -> ChatMessage {
        let message = ChatMessage(
            session: self,
            role: role,
            content: content,
            metadata: metadata
        )
        // Materialize the lazily-faulted relationship before appending.
        if messages == nil { messages = [] }
        messages?.append(message)
        messageCount += 1
        lastMessageAt = message.timestamp
        updatedAt = .now
        return message
    }
}
