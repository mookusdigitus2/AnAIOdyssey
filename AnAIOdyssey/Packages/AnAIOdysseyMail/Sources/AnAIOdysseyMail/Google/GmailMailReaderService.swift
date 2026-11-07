// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Maps Gmail's string identifiers to stable `Int64` ids and back.
///
/// `MailReaderServiceProtocol` models mailboxes/messages with numeric ids (matching Apple
/// Mail's ROWIDs), but Gmail identifies labels and messages by strings. This bidirectional
/// mapper assigns an incrementing id the first time it sees each key so the rest of the app
/// can use a uniform numeric id while still recovering the original Gmail string when needed.
final class GoogleIDMapper {
    /// Codable state for persisting a mapper across launches, so numeric ids in
    /// the on-disk mail cache still resolve to the same Gmail identifiers.
    struct Snapshot: Codable, Equatable {
        let stringToID: [String: Int64]
        let nextID: Int64
    }

    /// Guards the maps: list and detail reads run on different background threads.
    private let lock = NSLock()
    private var stringToID: [String: Int64] = [:]
    private var idToString: [Int64: String] = [:]
    private var nextID: Int64 = 1

    /// Returns the existing numeric id for `key`, allocating a new one on first sight.
    func id(for key: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let existing = stringToID[key] {
            return existing
        }
        // First time we've seen this key: allocate and record the next id.
        let value = nextID
        nextID += 1
        stringToID[key] = value
        idToString[value] = key
        return value
    }

    /// Recovers the original Gmail string for a previously-assigned numeric id, if known.
    func string(for id: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return idToString[id]
    }

    /// The current mapping state, for persistence alongside the mail cache.
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stringToID: stringToID, nextID: nextID)
    }

    /// Restores a persisted mapping so ids handed out before a relaunch stay valid.
    func restore(_ snapshot: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        stringToID = snapshot.stringToID
        idToString = Dictionary(
            snapshot.stringToID.map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        nextID = max(snapshot.nextID, (snapshot.stringToID.values.max() ?? 0) + 1)
    }
}

/// Both of a Gmail reader's id mappers, persisted with the unified mail cache.
///
/// Without this, a relaunch rebuilt the readers with empty mappers: cached
/// message rows still rendered, but tapping one either failed ("message not
/// found") or — once a fresh fetch re-allocated ids in a different order —
/// opened the wrong email.
struct GmailIDMapperState: Codable, Equatable {
    let labels: GoogleIDMapper.Snapshot
    let messages: GoogleIDMapper.Snapshot
}

/// `MailReaderServiceProtocol` backed by the Gmail REST API for a single account.
///
/// Cross-platform (iPadOS + macOS): authorization uses `ASWebAuthenticationSession` (PKCE)
/// handled by `MailAccountStore`, so this reader only needs an account-scoped
/// `GoogleOAuthService` to authorize requests. It adapts Gmail's labels/messages into the
/// app's `MailMailbox`/`MailMessageSummary` model, translating string ids via
/// `GoogleIDMapper`, and bridges Gmail's async API into the protocol's synchronous methods
/// via `awaitSync`. Read/starred state is derived from label membership.
public final class GmailMailReaderService: MailReaderServiceProtocol {
    public private(set) var accessStatus: MailAccessStatus = .mailNotConfigured

    private let oauth: GoogleOAuthService
    private let tokenStore: GoogleTokenStore
    private let accountID: String
    private let accountLabel: String
    private let gmail: GmailAPIClient
    private let labelMapper = GoogleIDMapper()
    private let messageMapper = GoogleIDMapper()

    /// Builds the Gmail reader over an account-scoped OAuth service + token store.
    public init(
        oauth: GoogleOAuthService,
        tokenStore: GoogleTokenStore,
        accountID: String,
        accountLabel: String,
        session: URLSession = .shared
    ) {
        self.oauth = oauth
        self.tokenStore = tokenStore
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.gmail = GmailAPIClient(oauth: oauth, session: session)
        refreshAccessStatus()
    }

    /// Reports `.available` only when the account holds usable credentials.
    public func refreshAccessStatus() {
        let signedIn = tokenStore.hasValidAccessToken || tokenStore.refreshTokenValue() != nil
        accessStatus = signedIn ? .available : .mailNotConfigured
    }

    /// Lists Gmail labels as mailboxes, honoring Gmail's real folder structure.
    ///
    /// Gmail identifies labels by opaque ids (e.g. `Label_57`) while the human name
    /// carries the hierarchy via `/` (e.g. `Work/Projects/Alpha`). We therefore map
    /// each kept label to a `displayPath` from its *name*, drop non-folder system
    /// labels (UNREAD/STARRED-as-flags, IMPORTANT, CHAT, CATEGORY_*), and order
    /// system folders (Inbox, Sent, …) ahead of user labels.
    public func listMailboxes() throws -> [MailMailbox] {
        guard accessStatus == .available else {
            throw MailReaderError.mailNotConfigured
        }
        return try awaitSync { [self] in
            let labels = try await gmail.listLabels()
            let folders = labels.compactMap { label -> (mailbox: MailMailbox, sort: GmailFolderMapping.SortKey)? in
                guard let mapping = GmailFolderMapping.mapping(for: label) else { return nil }
                let mailbox = MailMailbox(
                    id: labelMapper.id(for: label.id),
                    url: "gmail://\(label.id)",
                    totalCount: label.messagesTotal,
                    unreadCount: label.messagesUnread,
                    accountID: accountID,
                    accountLabel: accountLabel,
                    displayPath: mapping.path
                )
                return (mailbox, mapping.sortKey)
            }
            return folders
                .sorted { $0.sort < $1.sort }
                .map(\.mailbox)
        }
    }

    /// Lists messages in a label (defaulting to INBOX), mapped into `MailMessageSummary`.
    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        guard accessStatus == .available else {
            throw MailReaderError.mailNotConfigured
        }
        // Translate the numeric mailbox id back to a Gmail label, defaulting to INBOX.
        let labelID = mailboxID.flatMap { labelMapper.string(for: $0) } ?? "INBOX"
        return try awaitSync { [self] in
            let messages = try await gmail.listMessages(labelID: labelID, limit: limit)
            return messages.map { message in
                let rowID = messageMapper.id(for: message.id)
                return MailMessageSummary(
                    id: rowID,
                    messageID: rowID,
                    subject: message.subject,
                    senderAddress: message.senderAddress,
                    senderName: message.senderName,
                    dateReceived: message.dateReceived,
                    snippet: message.snippet,
                    isRead: !message.labelIDs.contains("UNREAD"),
                    isFlagged: message.labelIDs.contains("STARRED"),
                    mailboxURL: "gmail://\(labelID)",
                    accountID: accountID,
                    accountLabel: accountLabel
                )
            }
        }
    }

    /// Resolves the underlying Gmail API message id for a mapped row id.
    public func gmailMessageID(for messageRowID: Int64) -> String? {
        messageMapper.string(for: messageRowID)
    }

    /// Current label/message id mappings, persisted with the unified mail cache.
    func idMapperState() -> GmailIDMapperState {
        GmailIDMapperState(labels: labelMapper.snapshot(), messages: messageMapper.snapshot())
    }

    /// Restores persisted id mappings when readers are rebuilt at launch, so
    /// cached message rows still open the same Gmail message they were listed as.
    func restoreIDMapperState(_ state: GmailIDMapperState) {
        labelMapper.restore(state.labels)
        messageMapper.restore(state.messages)
    }

    /// Loads a single Gmail message's full detail, mapped into `MailMessageDetail`.
    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        guard accessStatus == .available else {
            throw MailReaderError.mailNotConfigured
        }
        // The numeric row id must map back to a known Gmail message id.
        guard let messageID = messageMapper.string(for: messageRowID) else {
            throw MailReaderError.messageNotFound(messageRowID)
        }
        return try awaitSync { [self] in
            let detail = try await gmail.fetchMessageDetail(id: messageID)
            let rowID = messageMapper.id(for: detail.summary.id)
            let summary = MailMessageSummary(
                id: rowID,
                messageID: rowID,
                subject: detail.summary.subject,
                senderAddress: detail.summary.senderAddress,
                senderName: detail.summary.senderName,
                dateReceived: detail.summary.dateReceived,
                snippet: detail.summary.snippet,
                isRead: !detail.summary.labelIDs.contains("UNREAD"),
                isFlagged: detail.summary.labelIDs.contains("STARRED"),
                mailboxURL: detail.summary.labelIDs.first.map { "gmail://\($0)" },
                accountID: accountID,
                accountLabel: accountLabel
            )
            return MailMessageDetail(
                summary: summary,
                bodyText: detail.bodyText ?? detail.summary.snippet,
                bodyHTML: detail.bodyHTML,
                to: detail.to,
                cc: detail.cc
            )
        }
    }

    // (helpers below)

    /// Bridges an async Gmail operation into a synchronous, throwing protocol method.
    ///
    /// The `MailReaderServiceProtocol` API is synchronous, so this runs the async work in a
    /// detached `Task` and blocks the calling thread on a semaphore until it completes,
    /// then re-throws any error. Must not be called on the main thread (callers invoke it
    /// off the main actor).
    private func awaitSync<T>(_ operation: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw MailReaderError.queryFailed("Gmail request did not complete.")
        }
    }
}

/// Translates Gmail labels into the app's folder model.
///
/// Decides which labels are real "folders" worth showing, gives system labels
/// friendly names, derives the hierarchy from user-label names (`Parent/Child`),
/// and provides an ordering that puts system folders first.
enum GmailFolderMapping {
    /// Sort position for a mapped folder: system folders (by canonical rank) come
    /// before user labels (sorted by their full lowercased path).
    struct SortKey: Comparable {
        let systemRank: Int       // Int.max for user labels → after system folders
        let path: [String]

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.systemRank != rhs.systemRank {
                return lhs.systemRank < rhs.systemRank
            }
            // Compare path components case-insensitively, element by element.
            let lhsPath = lhs.path.map { $0.lowercased() }
            let rhsPath = rhs.path.map { $0.lowercased() }
            for (a, b) in zip(lhsPath, rhsPath) where a != b {
                return a < b
            }
            return lhsPath.count < rhsPath.count
        }
    }

    /// Friendly display names for the system labels we surface, in display order.
    private static let systemFolders: [(id: String, title: String)] = [
        ("INBOX", "Inbox"),
        ("STARRED", "Starred"),
        ("SENT", "Sent"),
        ("DRAFT", "Drafts"),
        ("SPAM", "Spam"),
        ("TRASH", "Trash"),
    ]

    /// Returns the display path + sort key for a label, or `nil` to hide it.
    ///
    /// Hidden: system labels that are message *states*/smart-categories rather than
    /// folders (UNREAD, IMPORTANT, CHAT, and all `CATEGORY_*`), plus anything else
    /// not in the curated system set that isn't a user label.
    static func mapping(for label: GmailLabel) -> (path: [String], sortKey: SortKey)? {
        // User-created labels: hierarchy lives in the name, split on "/".
        if label.type == "user" {
            let components = label.name
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let path = components.isEmpty ? [label.name] : components
            return (path, SortKey(systemRank: .max, path: path))
        }

        // System labels: keep only the curated folder set, with friendly names.
        if let rank = systemFolders.firstIndex(where: { $0.id == label.id }) {
            return ([systemFolders[rank].title], SortKey(systemRank: rank, path: [systemFolders[rank].title]))
        }

        // Everything else (UNREAD, IMPORTANT, CHAT, CATEGORY_*, …) is not a folder.
        return nil
    }
}
