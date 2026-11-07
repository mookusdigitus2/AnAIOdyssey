// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A composed-but-unsent email draft.
///
/// The AI assistant can *create* these (new message, reply, or forward) but can
/// never send mail — drafts are surfaced in the Email workspace for the user to
/// review, edit, copy, and send themselves through their mail client. All fields
/// carry defaults so the model is CloudKit-mirror compatible.
@Model
public final class EmailDraft {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// Compose mode: `new`, `reply`, or `forward` (see `EmailDraftMode`).
    public var mode: String = EmailDraftMode.new.rawValue
    /// Comma-separated recipient addresses ("To").
    public var toRecipients: String = ""
    /// Comma-separated carbon-copy addresses ("Cc").
    public var ccRecipients: String = ""
    /// Subject line.
    public var subject: String = ""
    /// Body text of the draft.
    public var body: String = ""
    /// For reply/forward: the originating message's id (as a string), if known.
    public var originalMessageID: String?
    /// For reply/forward: the originating message's subject, for context.
    public var originalSubject: String?
    /// Owning mail account id when targeted at a specific account (else `nil`).
    public var accountID: String?
    /// Who created the draft: `ai` or `user`.
    public var source: String = "ai"
    /// Originating chat session when drafted by the assistant.
    public var sessionID: String?

    /// Bookkeeping timestamps; `updatedAt` drives Drafts list ordering.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Creates a draft; `id` defaults to a fresh UUID and timestamps to now.
    public init(
        id: String = UUID().uuidString,
        mode: String = EmailDraftMode.new.rawValue,
        toRecipients: String = "",
        ccRecipients: String = "",
        subject: String = "",
        body: String = "",
        originalMessageID: String? = nil,
        originalSubject: String? = nil,
        accountID: String? = nil,
        source: String = "ai",
        sessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.subject = subject
        self.body = body
        self.originalMessageID = originalMessageID
        self.originalSubject = originalSubject
        self.accountID = accountID
        self.source = source
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Compose modes for an `EmailDraft`, stored as the raw `mode` string.
public enum EmailDraftMode: String, Sendable, CaseIterable {
    /// A brand-new message.
    case new
    /// A reply to an existing message.
    case reply
    /// A reply to all recipients of an existing message.
    case replyAll = "reply_all"
    /// A forward of an existing message.
    case forward

    /// A user-facing label for the mode.
    public var displayName: String {
        switch self {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }
}
