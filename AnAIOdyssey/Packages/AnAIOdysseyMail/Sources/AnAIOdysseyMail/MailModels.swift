// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// A mailbox/folder as surfaced by any mail backend (Apple Mail or Gmail).
///
/// `url` is the backend-specific identifier (a `imap://`/local path for Apple Mail or a
/// `gmail://<labelID>` for Gmail); `displayName` derives a friendly label from it.
public struct MailMailbox: Identifiable, Sendable, Hashable, Codable {
    public let id: Int64
    public let url: String
    public let totalCount: Int
    public let unreadCount: Int
    /// Owning account id when surfaced through the multi-account reader (else `nil`).
    public let accountID: String?
    /// Friendly owning-account label for grouping in the UI (else `nil`).
    public let accountLabel: String?
    /// Hierarchical display path (leaf last), e.g. `["Work", "Projects", "Alpha"]`
    /// for a nested Gmail label. `nil` falls back to the `url`-derived name. This
    /// is what lets the UI render the real folder/label tree instead of a flat,
    /// id-named list.
    public let displayPath: [String]?

    /// Human-readable mailbox name: the leaf of `displayPath` when present,
    /// otherwise the last path component of `url`.
    public var displayName: String {
        if let leaf = displayPath?.last, !leaf.isEmpty {
            return leaf
        }
        if let name = url.split(separator: "/").last {
            return String(name)
        }
        return url
    }

    public init(
        id: Int64,
        url: String,
        totalCount: Int,
        unreadCount: Int,
        accountID: String? = nil,
        accountLabel: String? = nil,
        displayPath: [String]? = nil
    ) {
        self.id = id
        self.url = url
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.displayPath = displayPath
    }
}

/// Lightweight, list-friendly metadata for a single message.
///
/// `id` is the backend row id used to fetch details; `messageID` is the underlying
/// message identifier (Apple Mail's numeric message id, used to locate the `.emlx`).
/// `snippet` is the short indexed preview shown before the full body loads.
public struct MailMessageSummary: Identifiable, Sendable, Hashable, Codable {
    public let id: Int64
    public let messageID: Int64
    public let subject: String
    public let senderAddress: String
    public let senderName: String?
    public let dateReceived: Date?
    public let snippet: String?
    public let isRead: Bool
    public let isFlagged: Bool
    public let mailboxURL: String?
    /// Owning account id when surfaced through the multi-account reader (else `nil`).
    public let accountID: String?
    /// Friendly owning-account label shown on unified-inbox rows (else `nil`).
    public let accountLabel: String?

    public init(
        id: Int64,
        messageID: Int64,
        subject: String,
        senderAddress: String,
        senderName: String?,
        dateReceived: Date?,
        snippet: String?,
        isRead: Bool,
        isFlagged: Bool,
        mailboxURL: String?,
        accountID: String? = nil,
        accountLabel: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.subject = subject
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.dateReceived = dateReceived
        self.snippet = snippet
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.mailboxURL = mailboxURL
        self.accountID = accountID
        self.accountLabel = accountLabel
    }
}

/// A fully-loaded message: its summary plus body content and recipient headers.
///
/// `bodyText`/`bodyHTML` are populated from the parsed `.emlx` (or Gmail payload) when
/// available; `loadNotice` carries a user-facing explanation when only the indexed
/// preview could be loaded.
public struct MailMessageDetail: Sendable {
    public let summary: MailMessageSummary
    public let bodyText: String?
    public let bodyHTML: String?
    public let to: String?
    public let cc: String?
    /// Non-fatal notice when the full .emlx body could not be loaded locally.
    public let loadNotice: String?

    public init(
        summary: MailMessageSummary,
        bodyText: String?,
        bodyHTML: String?,
        to: String?,
        cc: String?,
        loadNotice: String? = nil
    ) {
        self.summary = summary
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.to = to
        self.cc = cc
        self.loadNotice = loadNotice
    }
}

/// Whether the mail backend is readable, blocked on permission, or not set up.
///
/// Drives UI state: `.available` enables browsing, `.permissionDenied` prompts for Full
/// Disk Access, and `.mailNotConfigured` means no usable mail source was found.
public enum MailAccessStatus: Sendable, Equatable {
    case available
    case permissionDenied
    case mailNotConfigured
}

/// All failures the mail reading pipeline can surface, with user-presentable messages.
///
/// Conforms to `LocalizedError` for display and `Equatable` for precise handling/testing.
public enum MailReaderError: Error, LocalizedError, Equatable {
    case permissionDenied
    case mailNotConfigured
    case databaseNotFound
    case databaseOpenFailed(String)
    case queryFailed(String)
    case messageNotFound(Int64)
    case emlxNotFound(Int64)
    case emlxParseFailed(String)

    /// Human-readable description for each failure case.
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Full Disk Access is required to read Apple Mail."
        case .mailNotConfigured:
            return "Apple Mail data was not found on this Mac."
        case .databaseNotFound:
            return "Mail Envelope Index database was not found."
        case .databaseOpenFailed(let detail):
            return "Could not open Mail database: \(detail)"
        case .queryFailed(let detail):
            return "Mail database query failed: \(detail)"
        case .messageNotFound(let id):
            return "Message \(id) was not found."
        case .emlxNotFound(let id):
            return "Could not locate .emlx file for message \(id)."
        case .emlxParseFailed(let detail):
            return "Could not parse .emlx file: \(detail)"
        }
    }
}
