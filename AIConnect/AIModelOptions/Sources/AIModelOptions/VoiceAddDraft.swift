// SPDX-License-Identifier: MIT
import Foundation

/// State of the "add ElevenLabs voice by ID" form, shared by Settings and the
/// chat voice sheet. Pure so it is testable on Linux.
public struct VoiceAddDraft: Equatable, Sendable {
    public var voiceID: String = ""
    /// Editable display name; prefilled from the lookup.
    public var name: String = ""
    public private(set) var lookedUp: ElevenLabsVoiceRecord?
    public var isLibrary = false
    public var error: String?

    public init() {}

    public static let footer = "Paste a voice ID from the ElevenLabs Voice Library."

    /// Lookup succeeded: remember the record and prefill the name unless the user typed one.
    public mutating func lookupSucceeded(_ record: ElevenLabsVoiceRecord, isLibrary: Bool) {
        lookedUp = record
        self.isLibrary = isLibrary
        error = nil
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = record.name }
    }

    /// ID edited: the old lookup no longer applies.
    public mutating func voiceIDChanged() {
        if lookedUp?.voiceID != voiceID.trimmingCharacters(in: .whitespacesAndNewlines) {
            lookedUp = nil
            name = ""
        }
        error = nil
    }

    public var canSave: Bool { lookedUp != nil }

    /// The record to persist, carrying the user's edited name.
    public var recordToSave: ElevenLabsVoiceRecord? {
        guard var record = lookedUp else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { record.name = trimmed }
        return record
    }

    public mutating func reset() { self = VoiceAddDraft() }
}

public enum VoiceRemovalPlan {
    /// Voice that becomes active when `removing` is removed; nil when it is not the active one.
    public static func replacement(removing: String, active: String,
                                   added: [VoiceOption], catalog: [VoiceOption]) -> VoiceOption? {
        guard removing == active else { return nil }
        return (added + catalog).first { $0.id != removing }
    }
}
