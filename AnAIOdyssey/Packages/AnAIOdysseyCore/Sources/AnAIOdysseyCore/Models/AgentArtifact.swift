// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Typed data object produced by or attached to agent work (email draft, note, etc.).
@Model
public final class AgentArtifact {
    public var id: String = ""
    public var taskID: String = ""
    /// Kind discriminator (`AgentArtifactKind` raw value).
    public var kind: String = AgentArtifactKind.taskNote.rawValue
    public var title: String = ""
    public var body: String = ""
    /// Optional link to an existing entity (e.g. EmailDraft id, Note id).
    public var linkedEntityID: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        kind: String = AgentArtifactKind.taskNote.rawValue,
        title: String = "",
        body: String = "",
        linkedEntityID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.body = body
        self.linkedEntityID = linkedEntityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum AgentArtifactKind: String, Sendable, CaseIterable {
    case email
    case taskNote = "task_note"
    case researcherMessage = "researcher_message"
    case chatToEmail = "chat_to_email"
    case generic

    public var displayName: String {
        switch self {
        case .email: return "Email"
        case .taskNote: return "Task Note"
        case .researcherMessage: return "Researcher Message"
        case .chatToEmail: return "Chat → Email"
        case .generic: return "Generic"
        }
    }
}
