// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// A `MailReaderServiceProtocol` that fans out across every configured account
/// and presents a unified inbox plus each account's mailboxes.
///
/// It owns one child reader per signed-in account (Gmail today; Apple Mail on
/// macOS) and exposes them through a single numeric id space so the existing
/// `EmailView` keeps working unchanged. A virtual "All Inboxes" mailbox merges
/// each account's INBOX, sorted newest-first. Child readers are rebuilt only when
/// the set of accounts changes (`reload()`), keeping per-message ids stable for
/// the duration of a browsing session so detail loads route correctly.
///
/// Reads happen off the main actor (the Gmail child blocks on the network), so
/// child construction — which touches the main-actor `MailAccountStore` — is done
/// up front in `reload()`; the read methods only touch already-built children.
///
/// To keep the Email tab instant, the last successfully fetched mailboxes and
/// per-mailbox message lists are cached in memory (guarded by `lock`). The UI can
/// read the cache synchronously for an immediate render, then call the `async`
/// refresh methods (which run the blocking child reads off the main thread) to
/// update in the background. `@unchecked Sendable` is sound because all mutable
/// state is serialized through `lock` and children are built up front.
public final class UnifiedMailReaderService: MailReaderServiceProtocol, @unchecked Sendable {
    /// Sentinel id for the synthetic "All Inboxes" mailbox.
    public static let unifiedInboxID: Int64 = -1

    /// One backing account reader with its display label and (optional) account id.
    private struct Child {
        let label: String
        let accountID: String?
        let reader: any MailReaderServiceProtocol
    }

    public private(set) var accessStatus: MailAccessStatus = .mailNotConfigured

    private let accountStore: MailAccountStore
    private let includeAppleMail: Bool
    private let session: URLSession
    private let cacheFileManager: FileManager
    private let cacheAppSupportDirectory: URL?
    private let extraEmailAdapters: [any EmailProviderAdapter]

    private var children: [Child] = []

    /// Serializes access to the global id maps (reads run off the main actor).
    private let lock = NSRecursiveLock()
    private var nextMailboxGlobalID: Int64 = 1
    private var mailboxKeyToGlobal: [String: Int64] = [:]
    private var globalToMailbox: [Int64: (childIndex: Int, childMailboxID: Int64)] = [:]
    private var nextMessageGlobalID: Int64 = 1
    private var messageKeyToGlobal: [String: Int64] = [:]
    private var globalToMessage: [Int64: (childIndex: Int, childMessageID: Int64)] = [:]

    /// Cache of the last successful fetches, for instant rendering on tab open.
    private var cachedMailboxesValue: [MailMailbox] = []
    private var cachedMessagesByMailbox: [Int64: [MailMessageSummary]] = [:]

    /// Builds the reader and its child readers from the current account list.
    @MainActor
    public init(
        accountStore: MailAccountStore,
        includeAppleMail: Bool,
        session: URLSession = .shared,
        cacheFileManager: FileManager = .default,
        cacheAppSupportDirectory: URL? = nil,
        extraEmailAdapters: [any EmailProviderAdapter] = []
    ) {
        self.accountStore = accountStore
        self.includeAppleMail = includeAppleMail
        self.session = session
        self.cacheFileManager = cacheFileManager
        self.cacheAppSupportDirectory = cacheAppSupportDirectory
        self.extraEmailAdapters = extraEmailAdapters
        reload()
        restorePersistedCacheIfAvailable()
    }

    /// Rebuilds child readers from the current accounts and resets the id maps.
    ///
    /// Call after accounts change (sign-in/out) so newly added accounts appear and
    /// removed ones disappear.
    @MainActor
    public func reload() {
        var built: [Child] = []
        #if os(macOS)
        // Apple Mail is a built-in, always-present local source on macOS.
        if includeAppleMail {
            built.append(Child(label: "Apple Mail", accountID: nil, reader: MailReaderService()))
        }
        #endif
        // One Gmail reader per signed-in Google account, via the Google Auth adapter.
        var adapters: [any EmailProviderAdapter] = extraEmailAdapters
        adapters.append(contentsOf: WorkspaceConnectionManager.emailAdapters(
            accountStore: accountStore,
            includeAppleMail: false,
            session: session
        ))
        var seenIDs = Set<String>()
        for adapter in adapters where adapter.isAvailable {
            guard seenIDs.insert(adapter.connectionID).inserted else { continue }
            let accountID = (adapter as? GoogleAuthAdapter)?.account.id ?? adapter.connectionID
            built.append(Child(label: adapter.displayName, accountID: accountID, reader: adapter.makeMailReader()))
        }

        children = built
        ConnectionDebug.log(
            "UnifiedMail",
            "reload built children=\(built.count) googleAccounts=\(accountStore.googleAccounts.count) signedIn=\(accountStore.googleAccounts.filter { accountStore.isSignedIn($0) }.count) includeAppleMail=\(includeAppleMail)"
        )
        for child in built {
            ConnectionDebug.log(
                "UnifiedMail",
                "child label=\(child.label) account=\(child.accountID.map(ConnectionDebug.account) ?? "local") status=\(String(describing: child.reader.accessStatus))"
            )
        }
        lock.lock()
        nextMailboxGlobalID = 1; mailboxKeyToGlobal = [:]; globalToMailbox = [:]
        nextMessageGlobalID = 1; messageKeyToGlobal = [:]; globalToMessage = [:]
        // The id space is reset, so the old cache no longer maps cleanly.
        cachedMailboxesValue = []
        cachedMessagesByMailbox = [:]
        lock.unlock()
        recomputeStatus()
        restorePersistedCacheIfAvailable()
    }

    /// Number of signed-in account readers currently backing the unified view.
    public var childCount: Int { children.count }

    /// Refreshes every child's access status and recomputes the aggregate status.
    public func refreshAccessStatus() {
        for child in children { child.reader.refreshAccessStatus() }
        recomputeStatus()
        ConnectionDebug.log(
            "UnifiedMail",
            "access refreshed aggregate=\(String(describing: accessStatus)) children=\(children.map { "\($0.label):\(String(describing: $0.reader.accessStatus))" }.joined(separator: ","))"
        )
    }

    /// Aggregate status: available if any child is, else permission-denied if any is, else not-configured.
    private func recomputeStatus() {
        if children.contains(where: { $0.reader.accessStatus == .available }) {
            accessStatus = .available
        } else if children.contains(where: { $0.reader.accessStatus == .permissionDenied }) {
            accessStatus = .permissionDenied
        } else {
            accessStatus = .mailNotConfigured
        }
    }

    /// Lists the virtual "All Inboxes" mailbox followed by each account's mailboxes.
    public func listMailboxes() throws -> [MailMailbox] {
        guard accessStatus == .available else {
            ConnectionDebug.log("UnifiedMail", "list mailboxes blocked aggregate=\(String(describing: accessStatus))")
            throw MailReaderError.mailNotConfigured
        }
        var result: [MailMailbox] = [
            MailMailbox(
                id: Self.unifiedInboxID,
                url: "unified:///All Inboxes",
                totalCount: 0,
                unreadCount: 0
            ),
        ]
        var successfulChildren = 0
        var firstError: Error?
        for (index, child) in children.enumerated() where child.reader.accessStatus == .available {
            let boxes: [MailMailbox]
            do {
                boxes = try child.reader.listMailboxes()
                successfulChildren += 1
                ConnectionDebug.log("UnifiedMail", "mailboxes child=\(child.label) count=\(boxes.count)")
            } catch {
                if firstError == nil { firstError = error }
                ConnectionDebug.log("UnifiedMail", "mailboxes child=\(child.label) failed error=\(error.localizedDescription)")
                continue
            }
            for box in boxes {
                let gid = globalMailboxID(childIndex: index, childMailboxID: box.id, url: box.url)
                result.append(MailMailbox(
                    id: gid,
                    url: box.url,
                    totalCount: box.totalCount,
                    unreadCount: box.unreadCount,
                    accountID: child.accountID,
                    accountLabel: child.label,
                    displayPath: box.displayPath
                ))
            }
        }
        if successfulChildren == 0, let firstError {
            ConnectionDebug.log("UnifiedMail", "list mailboxes failed: every available child failed")
            throw firstError
        }
        cacheMailboxes(result)
        ConnectionDebug.log("UnifiedMail", "list mailboxes complete count=\(result.count)")
        return result
    }

    /// Lists messages for a mailbox, or the merged inbox when `nil`/the sentinel id.
    public func listMessages(mailboxID: Int64?, limit: Int) throws -> [MailMessageSummary] {
        guard accessStatus == .available else {
            ConnectionDebug.log("UnifiedMail", "list messages blocked aggregate=\(String(describing: accessStatus))")
            throw MailReaderError.mailNotConfigured
        }

        // Unified inbox: merge each account's INBOX, newest first.
        if mailboxID == nil || mailboxID == Self.unifiedInboxID {
            var merged: [MailMessageSummary] = []
            var successfulChildren = 0
            var firstError: Error?
            for (index, child) in children.enumerated() where child.reader.accessStatus == .available {
                let msgs: [MailMessageSummary]
                do {
                    msgs = try child.reader.listMessages(mailboxID: nil, limit: limit)
                    successfulChildren += 1
                    ConnectionDebug.log("UnifiedMail", "messages child=\(child.label) count=\(msgs.count)")
                } catch {
                    if firstError == nil { firstError = error }
                    ConnectionDebug.log("UnifiedMail", "messages child=\(child.label) failed error=\(error.localizedDescription)")
                    continue
                }
                for message in msgs {
                    merged.append(remap(message, childIndex: index, label: child.label, accountID: child.accountID))
                }
            }
            if successfulChildren == 0, let firstError {
                ConnectionDebug.log("UnifiedMail", "list messages failed: every available child failed")
                throw firstError
            }
            merged.sort { ($0.dateReceived ?? .distantPast) > ($1.dateReceived ?? .distantPast) }
            let capped = Array(merged.prefix(limit))
            cacheMessages(capped, forMailboxID: Self.unifiedInboxID)
            ConnectionDebug.log("UnifiedMail", "unified messages complete count=\(capped.count)")
            return capped
        }

        // Specific mailbox: route to its owning child.
        guard let mailboxID, let mapping = mailboxMapping(for: mailboxID) else {
            throw MailReaderError.mailNotConfigured
        }
        let child = children[mapping.childIndex]
        let msgs = try child.reader.listMessages(mailboxID: mapping.childMailboxID, limit: limit)
        let remapped = msgs.map { remap($0, childIndex: mapping.childIndex, label: child.label, accountID: child.accountID) }
        cacheMessages(remapped, forMailboxID: mailboxID)
        return remapped
    }

    /// Routes a detail load back to the child that produced the message.
    public func loadMessageDetail(messageRowID: Int64) throws -> MailMessageDetail {
        guard let mapping = messageMapping(for: messageRowID) else {
            throw MailReaderError.messageNotFound(messageRowID)
        }
        let child = children[mapping.childIndex]
        let detail = try child.reader.loadMessageDetail(messageRowID: mapping.childMessageID)
        // Re-stamp the summary with the global id + account attribution.
        let s = detail.summary
        let summary = MailMessageSummary(
            id: messageRowID,
            messageID: messageRowID,
            subject: s.subject,
            senderAddress: s.senderAddress,
            senderName: s.senderName,
            dateReceived: s.dateReceived,
            snippet: s.snippet,
            isRead: s.isRead,
            isFlagged: s.isFlagged,
            mailboxURL: s.mailboxURL,
            accountID: child.accountID,
            accountLabel: child.label
        )
        return MailMessageDetail(
            summary: summary,
            bodyText: detail.bodyText,
            bodyHTML: detail.bodyHTML,
            to: detail.to,
            cc: detail.cc,
            loadNotice: detail.loadNotice
        )
    }

    // MARK: - Cache

    /// Last-fetched mailboxes (empty until the first successful load). Instant.
    public func cachedMailboxes() -> [MailMailbox] {
        lock.lock(); defer { lock.unlock() }
        return cachedMailboxesValue
    }

    /// Last-fetched messages for a mailbox (`nil`/sentinel → unified inbox). Instant.
    public func cachedMessages(forMailboxID mailboxID: Int64?) -> [MailMessageSummary] {
        lock.lock(); defer { lock.unlock() }
        return cachedMessagesByMailbox[mailboxID ?? Self.unifiedInboxID] ?? []
    }

    /// Whether any data has been cached yet (used to decide the empty-vs-stale UI).
    public var hasCachedData: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cachedMailboxesValue.isEmpty || !cachedMessagesByMailbox.isEmpty
    }

    private func cacheMailboxes(_ mailboxes: [MailMailbox]) {
        lock.lock(); defer { lock.unlock() }
        cachedMailboxesValue = mailboxes
    }

    private func cacheMessages(_ messages: [MailMessageSummary], forMailboxID mailboxID: Int64) {
        lock.lock(); defer { lock.unlock() }
        cachedMessagesByMailbox[mailboxID] = messages
    }

    @MainActor
    private func accountFingerprint() -> String {
        var parts: [String] = []
        if includeAppleMail {
            parts.append("apple")
        }
        for account in accountStore.googleAccounts where accountStore.isSignedIn(account) {
            parts.append(account.id)
        }
        return parts.joined(separator: "|")
    }

    private func currentAccountFingerprint() async -> String {
        await MainActor.run { accountFingerprint() }
    }

    @MainActor
    private func restorePersistedCacheIfAvailable() {
        guard let snapshot = EmailCachePersistence.load(
            fileManager: cacheFileManager,
            appSupportDirectory: cacheAppSupportDirectory
        ) else { return }
        guard snapshot.accountFingerprint == accountFingerprint() else { return }

        lock.lock()
        cachedMailboxesValue = snapshot.mailboxes
        cachedMessagesByMailbox = snapshot.messagesByMailbox.reduce(into: [:]) { result, entry in
            guard let mailboxID = Int64(entry.key) else { return }
            result[mailboxID] = entry.value
        }
        nextMailboxGlobalID = snapshot.nextMailboxGlobalID
        nextMessageGlobalID = snapshot.nextMessageGlobalID
        mailboxKeyToGlobal = snapshot.mailboxKeyToGlobal
        globalToMailbox = snapshot.globalToMailbox.reduce(into: [:]) { result, entry in
            guard let globalID = Int64(entry.key) else { return }
            result[globalID] = (entry.value.childIndex, entry.value.childMailboxID)
        }
        messageKeyToGlobal = snapshot.messageKeyToGlobal
        globalToMessage = snapshot.globalToMessage.reduce(into: [:]) { result, entry in
            guard let globalID = Int64(entry.key) else { return }
            result[globalID] = (entry.value.childIndex, entry.value.childMessageID)
        }
        lock.unlock()

        // Seed each Gmail child's numeric↔string id mapper from the snapshot so
        // the child-level ids referenced above resolve to the right Gmail
        // messages before (and regardless of) the next network refresh.
        if let mappers = snapshot.gmailMappersByAccountID {
            for child in children {
                guard let accountID = child.accountID,
                      let state = mappers[accountID],
                      let gmailReader = child.reader as? GmailMailReaderService else { continue }
                gmailReader.restoreIDMapperState(state)
            }
        }
    }

    private func persistCacheSnapshot(accountFingerprint: String) {
        // Capture each Gmail child's id mappings so cached rows survive a relaunch.
        let gmailMappers: [String: GmailIDMapperState] = children.reduce(into: [:]) { result, child in
            guard let accountID = child.accountID,
                  let gmailReader = child.reader as? GmailMailReaderService else { return }
            result[accountID] = gmailReader.idMapperState()
        }

        lock.lock()
        let snapshot = UnifiedMailCacheSnapshot(
            accountFingerprint: accountFingerprint,
            mailboxes: cachedMailboxesValue,
            messagesByMailbox: cachedMessagesByMailbox.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = entry.value
            },
            nextMailboxGlobalID: nextMailboxGlobalID,
            nextMessageGlobalID: nextMessageGlobalID,
            mailboxKeyToGlobal: mailboxKeyToGlobal,
            globalToMailbox: globalToMailbox.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = UnifiedMailCacheSnapshot.MailboxMapping(
                    childIndex: entry.value.childIndex,
                    childMailboxID: entry.value.childMailboxID
                )
            },
            messageKeyToGlobal: messageKeyToGlobal,
            globalToMessage: globalToMessage.reduce(into: [:]) { result, entry in
                result[String(entry.key)] = UnifiedMailCacheSnapshot.MessageMapping(
                    childIndex: entry.value.childIndex,
                    childMessageID: entry.value.childMessageID
                )
            },
            gmailMappersByAccountID: gmailMappers
        )
        lock.unlock()

        EmailCachePersistence.save(
            snapshot,
            fileManager: cacheFileManager,
            appSupportDirectory: cacheAppSupportDirectory
        )
    }

    // MARK: - Async refresh (runs blocking child reads off the main thread)

    /// Fetches mailboxes off the main thread, updating the cache as a side effect.
    public func refreshMailboxes() async throws -> [MailMailbox] {
        let fingerprint = await currentAccountFingerprint()
        let mailboxes = try await runOffMain { try self.listMailboxes() }
        persistCacheSnapshot(accountFingerprint: fingerprint)
        return mailboxes
    }

    /// Fetches a mailbox's messages off the main thread, updating the cache.
    public func refreshMessages(mailboxID: Int64?, limit: Int) async throws -> [MailMessageSummary] {
        let fingerprint = await currentAccountFingerprint()
        let messages = try await runOffMain { try self.listMessages(mailboxID: mailboxID, limit: limit) }
        persistCacheSnapshot(accountFingerprint: fingerprint)
        return messages
    }

    /// Loads a message's full detail off the main thread (the body fetch blocks).
    public func loadMessageDetailAsync(messageRowID: Int64) async throws -> MailMessageDetail {
        try await runOffMain { try self.loadMessageDetail(messageRowID: messageRowID) }
    }

    /// Prefetches mailboxes and the unified inbox at launch, persisting a copy for
    /// the next session. Never throws — startup must not fail when mail is offline.
    public func warmUp(messageLimit: Int = 50) async {
        refreshAccessStatus()
        guard accessStatus == .available else {
            ConnectionDebug.log("UnifiedMail", "warm-up skipped status=\(String(describing: accessStatus))")
            return
        }
        ConnectionDebug.log("UnifiedMail", "warm-up start limit=\(messageLimit)")
        do {
            let boxes = try await refreshMailboxes()
            let messages = try await refreshMessages(mailboxID: Self.unifiedInboxID, limit: messageLimit)
            ConnectionDebug.log("UnifiedMail", "warm-up complete mailboxes=\(boxes.count) messages=\(messages.count)")
        } catch {
            ConnectionDebug.log("UnifiedMail", "warm-up failed error=\(error.localizedDescription)")
            // Keep any restored on-disk cache when the network refresh fails.
        }
    }

    /// Runs blocking work on a background queue, bridged to async.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Id mapping

    /// Re-stamps a child summary with a stable global id and account attribution.
    private func remap(_ m: MailMessageSummary, childIndex: Int, label: String, accountID: String?) -> MailMessageSummary {
        let gid = globalMessageID(childIndex: childIndex, childMessageID: m.id)
        return MailMessageSummary(
            id: gid,
            messageID: gid,
            subject: m.subject,
            senderAddress: m.senderAddress,
            senderName: m.senderName,
            dateReceived: m.dateReceived,
            snippet: m.snippet,
            isRead: m.isRead,
            isFlagged: m.isFlagged,
            mailboxURL: m.mailboxURL,
            accountID: accountID,
            accountLabel: m.accountLabel ?? label
        )
    }

    /// Allocates (or reuses) a stable global mailbox id for a child mailbox.
    private func globalMailboxID(childIndex: Int, childMailboxID: Int64, url: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let key = "\(childIndex)|\(url)"
        if let existing = mailboxKeyToGlobal[key] { return existing }
        let gid = nextMailboxGlobalID
        nextMailboxGlobalID += 1
        mailboxKeyToGlobal[key] = gid
        globalToMailbox[gid] = (childIndex, childMailboxID)
        return gid
    }

    private func mailboxMapping(for globalID: Int64) -> (childIndex: Int, childMailboxID: Int64)? {
        lock.lock(); defer { lock.unlock() }
        return globalToMailbox[globalID]
    }

    /// Allocates (or reuses) a stable global message id for a child message.
    private func globalMessageID(childIndex: Int, childMessageID: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let key = "\(childIndex)|\(childMessageID)"
        if let existing = messageKeyToGlobal[key] { return existing }
        let gid = nextMessageGlobalID
        nextMessageGlobalID += 1
        messageKeyToGlobal[key] = gid
        globalToMessage[gid] = (childIndex, childMessageID)
        return gid
    }

    private func messageMapping(for globalID: Int64) -> (childIndex: Int, childMessageID: Int64)? {
        lock.lock(); defer { lock.unlock() }
        return globalToMessage[globalID]
    }

    /// Resolves a global message row to its Gmail account + API message id for sending.
    public func gmailSendContext(forGlobalMessageRowID globalID: Int64) -> (accountID: String, gmailMessageID: String)? {
        lock.lock()
        let mapping = globalToMessage[globalID]
        let childIndex = mapping?.childIndex
        let childMessageID = mapping?.childMessageID
        lock.unlock()
        guard let childIndex, let childMessageID else { return nil }
        let child = children[childIndex]
        guard let accountID = child.accountID,
              let gmailReader = child.reader as? GmailMailReaderService,
              let gmailID = gmailReader.gmailMessageID(for: childMessageID) else {
            return nil
        }
        return (accountID, gmailID)
    }
}
