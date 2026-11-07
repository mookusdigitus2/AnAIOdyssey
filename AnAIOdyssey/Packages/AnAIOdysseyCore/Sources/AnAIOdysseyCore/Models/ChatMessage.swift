// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A single message within a `ChatSession`.
///
/// Owned by its session via a cascade relationship. `sessionID` is denormalized
/// alongside the `session` relationship so messages can be fetched/sorted by
/// session id without faulting the parent.
@Model
public final class ChatMessage {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// Denormalized parent session ID for predicate-based fetches.
    public var sessionID: String = ""
    /// Author role ("user"/"assistant"/"system"/...).
    public var role: String = ""
    /// Message body.
    public var content: String = ""
    /// Optional JSON-encoded extra data (tool calls, token usage, attachments).
    public var metadata: String?
    /// When the message was created; the chronological sort key.
    public var timestamp: Date = Date()

    /// Inverse side of the cascade relationship to the owning `ChatSession`.
    public var session: ChatSession?

    /// Creates a message bound to `session`, copying its ID into `sessionID`.
    public init(
        id: String = UUID().uuidString,
        session: ChatSession,
        role: String,
        content: String,
        metadata: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.sessionID = session.id
        self.role = role
        self.content = content
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
