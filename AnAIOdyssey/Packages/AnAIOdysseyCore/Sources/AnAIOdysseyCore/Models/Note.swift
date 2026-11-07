// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Distinguishes a free-form note from a checklist — mirrors Python
/// `Note.note_type`. Stored as the raw `noteType` string on `Note`.
public enum NoteType: String, Codable, Sendable {
    /// Plain text/markdown note (uses `content`).
    case note
    /// Checklist note (uses `checklistItems`).
    case checklist
}

/// A note or checklist — the app's general-purpose capture surface, usable by
/// both the user and AI agents.
///
/// A single model backs both note flavours (see `noteType`); `content` is used
/// for text notes and `checklistItems` for checklists. The many optional fields
/// support features layered on over time (pinning, labels/colors, AI
/// classification, recurrence) while mirroring the legacy Python schema.
@Model
public final class Note {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// Optional owning user.
    public var owner: String?
    /// Owning folder id in the notes tree (`nil` = root). See `Folder`.
    public var parentID: String?
    /// Note title / heading.
    public var title: String = ""
    /// Body text for plain notes (`nil`/unused for checklists).
    public var content: String?
    /// Rows for checklist notes (empty for plain notes).
    public var checklistItems: [ChecklistItem] = []
    /// Which flavour this is, as a `NoteType` raw value.
    public var noteType: String = NoteType.note.rawValue
    /// Optional presentation hints.
    public var color: String?
    public var label: String?
    /// Whether the note is pinned to the top of lists.
    public var pinned: Bool = false
    /// Whether the note is archived (hidden from default listings).
    public var archived: Bool = false
    /// Optional due date, stored as a string to match the legacy schema.
    public var dueDate: String?
    /// Origin of the note ("user", or an AI/agent source).
    public var source: String = "user"
    /// Optional originating chat session.
    public var sessionID: String?
    /// Manual ordering hint.
    public var sortOrder: Int = 0
    /// Optional attached image URL.
    public var imageURL: String?
    /// Recurrence rule for repeating notes/reminders ("none" when not repeating).
    public var repeatRule: String = "none"
    /// AI-assigned category plus a hash of the classified content, used to avoid
    /// re-classifying unchanged notes.
    public var aiClassification: String?
    public var aiContentHash: String?
    /// Agent session that created/modified this note, for provenance.
    public var agentSessionID: String?

    /// Bookkeeping timestamps; `updatedAt` drives most sort orders.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Creates a note; `id` defaults to a fresh UUID and it defaults to a plain
    /// (non-checklist) user note.
    public init(
        id: String = UUID().uuidString,
        owner: String? = nil,
        parentID: String? = nil,
        title: String = "",
        content: String? = nil,
        checklistItems: [ChecklistItem] = [],
        noteType: String = NoteType.note.rawValue,
        color: String? = nil,
        label: String? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        dueDate: String? = nil,
        source: String = "user",
        sessionID: String? = nil,
        sortOrder: Int = 0,
        imageURL: String? = nil,
        repeatRule: String = "none",
        aiClassification: String? = nil,
        aiContentHash: String? = nil,
        agentSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.owner = owner
        self.parentID = parentID
        self.title = title
        self.content = content
        self.checklistItems = checklistItems
        self.noteType = noteType
        self.color = color
        self.label = label
        self.pinned = pinned
        self.archived = archived
        self.dueDate = dueDate
        self.source = source
        self.sessionID = sessionID
        self.sortOrder = sortOrder
        self.imageURL = imageURL
        self.repeatRule = repeatRule
        self.aiClassification = aiClassification
        self.aiContentHash = aiContentHash
        self.agentSessionID = agentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Flips the checked state of the checklist item at `index` and bumps
    /// `updatedAt`.
    ///
    /// Safely no-ops when `index` is out of bounds so callers don't have to
    /// bounds-check against a possibly-stale UI index.
    public func toggleChecklistItem(at index: Int) {
        // Ignore stale/invalid indices (e.g. the list changed under the UI).
        guard checklistItems.indices.contains(index) else { return }
        checklistItems[index].done.toggle()
        updatedAt = .now
    }
}
