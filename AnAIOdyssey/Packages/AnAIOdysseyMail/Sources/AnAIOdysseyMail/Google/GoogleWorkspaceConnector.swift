// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Outcome of a Google sign-in that also started mail download and calendar sync.
public struct GoogleWorkspaceConnectionResult: Sendable {
    public let account: MailAccount
    public let calendarEventCount: Int
    public let downloadedMail: Bool
    public let mailError: String?
    public let calendarError: String?

    public init(
        account: MailAccount,
        calendarEventCount: Int,
        downloadedMail: Bool,
        mailError: String?,
        calendarError: String?
    ) {
        self.account = account
        self.calendarEventCount = calendarEventCount
        self.downloadedMail = downloadedMail
        self.mailError = mailError
        self.calendarError = calendarError
    }

    /// Combined status line for Settings / Email after a successful login.
    public var summary: String {
        var parts: [String] = ["Signed in as \(account.label)."]
        if downloadedMail {
            parts.append("Mail download started.")
        }
        if calendarEventCount > 0 {
            parts.append("Synced \(calendarEventCount) Google Calendar event(s).")
        }
        if let mailError {
            parts.append(mailError)
        }
        if let calendarError {
            parts.append(calendarError)
        }
        return parts.joined(separator: " ")
    }
}

/// Single post-auth path: persist Google tokens, then download mail and sync calendar.
@MainActor
public struct GoogleWorkspaceConnector {
    private let accountStore: MailAccountStore
    private let mailReader: UnifiedMailReaderService?
    private let calendarCache: (any CalendarEventRepositoryProtocol)?

    public init(
        accountStore: MailAccountStore,
        mailReader: (any MailReaderServiceProtocol)?,
        calendarCache: (any CalendarEventRepositoryProtocol)?
    ) {
        self.accountStore = accountStore
        self.mailReader = mailReader as? UnifiedMailReaderService
        self.calendarCache = calendarCache
    }

    /// Authenticate with Google, save tokens, then automatically download mail
    /// and synchronize the next 90 days of Google Calendar.
    @discardableResult
    public func connect(existing: MailAccount? = nil) async throws -> GoogleWorkspaceConnectionResult {
        ConnectionDebug.log(
            "WorkspaceConnector",
            "connect start mode=\(existing == nil ? "add" : "reconnect")"
        )
        let account = try await accountStore.authenticateAndPersistGoogleAccount(existing: existing)
        ConnectionDebug.log(
            "WorkspaceConnector",
            "authentication complete account=\(ConnectionDebug.account(account.id)) signedIn=\(accountStore.isSignedIn(account))"
        )

        var downloadedMail = false
        var mailError: String?
        if let mailReader {
            mailReader.reload()
            mailReader.refreshAccessStatus()
            ConnectionDebug.log(
                "WorkspaceConnector",
                "mail reader rebuilt children=\(mailReader.childCount) status=\(String(describing: mailReader.accessStatus))"
            )
            if mailReader.accessStatus == .available {
                do {
                    let mailboxes = try await mailReader.refreshMailboxes()
                    let messages = try await mailReader.refreshMessages(
                        mailboxID: UnifiedMailReaderService.unifiedInboxID,
                        limit: 50
                    )
                    downloadedMail = true
                    ConnectionDebug.log(
                        "WorkspaceConnector",
                        "mail sync complete mailboxes=\(mailboxes.count) messages=\(messages.count)"
                    )
                } catch {
                    mailError = "Mail sync failed: \(error.localizedDescription)"
                    ConnectionDebug.log(
                        "WorkspaceConnector",
                        "mail sync failed error=\(error.localizedDescription)"
                    )
                }
            } else {
                mailError = "Mail did not become available after sign-in. Use Refresh on the Email tab."
                ConnectionDebug.log("WorkspaceConnector", "mail unavailable after authentication")
            }
        } else {
            ConnectionDebug.log("WorkspaceConnector", "no unified mail reader was injected")
        }

        var calendarEventCount = 0
        var calendarError: String?
        if let calendarCache {
            do {
                ConnectionDebug.log("WorkspaceConnector", "calendar sync start")
                calendarEventCount = try await syncCalendar(for: account, cache: calendarCache)
                ConnectionDebug.log("WorkspaceConnector", "calendar sync complete events=\(calendarEventCount)")
            } catch {
                calendarError = error.localizedDescription
                ConnectionDebug.log("WorkspaceConnector", "calendar sync failed error=\(error.localizedDescription)")
            }
        } else {
            ConnectionDebug.log("WorkspaceConnector", "calendar sync skipped: no cache")
        }

        let result = GoogleWorkspaceConnectionResult(
            account: account,
            calendarEventCount: calendarEventCount,
            downloadedMail: downloadedMail,
            mailError: mailError,
            calendarError: calendarError
        )
        ConnectionDebug.log(
            "WorkspaceConnector",
            "connect complete mailOK=\(downloadedMail) calendarError=\(calendarError != nil)"
        )
        return result
    }

    private func syncCalendar(
        for account: MailAccount,
        cache: any CalendarEventRepositoryProtocol
    ) async throws -> Int {
        let oauth = accountStore.oauthService(for: account)
        let api = GoogleCalendarAPIClient(oauth: oauth)
        let sync = GoogleCalendarSyncService(api: api, cache: cache)
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 90, to: start) ?? start
        return try await sync.syncEvents(from: start, to: end)
    }
}
