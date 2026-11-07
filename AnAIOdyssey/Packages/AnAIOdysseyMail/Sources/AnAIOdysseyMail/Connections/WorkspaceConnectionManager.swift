// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Combine
import Foundation
import AnAIOdysseyCore
import SwiftUI

/// Singleton owner of the user's email/calendar connections.
///
/// Google Auth is one adapter in the set: each signed-in Google account exposes
/// both Gmail (`EmailProviderAdapter`) and Google Calendar (`CalendarProviderAdapter`).
/// Apple Mail (macOS) is an email-only adapter. `CalendarService` still owns EventKit
/// and merges these Google adapters so iOS/iPadOS can read and write Google Calendar
/// without the account appearing in the system Calendar app.
@MainActor
public final class WorkspaceConnectionManager: ObservableObject {
    public static let shared = WorkspaceConnectionManager()

    public let accountStore: MailAccountStore
    public let includeAppleMail: Bool

    private let session: URLSession
    private var calendarCache: (any CalendarEventRepositoryProtocol)?
    private weak var calendarService: CalendarService?
    private var accountObserver: AnyCancellable?
    /// Extra adapters (preview inbox, tests) merged into ``emailAdapters()``.
    public private(set) var installedEmailAdapters: [any EmailProviderAdapter] = []

    /// Test/app designated initializer. Production uses ``shared``.
    public init(
        accountStore: MailAccountStore? = nil,
        includeAppleMail: Bool? = nil,
        session: URLSession = .shared
    ) {
        self.accountStore = accountStore ?? MailAccountStore()
        #if os(macOS)
        self.includeAppleMail = includeAppleMail ?? true
        #else
        self.includeAppleMail = includeAppleMail ?? false
        #endif
        self.session = session
        accountObserver = self.accountStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.pushCalendarProviders()
            }
        }
    }

    /// The current connection set (Google accounts + platform built-ins).
    public var connections: [WorkspaceConnection] {
        var result: [WorkspaceConnection] = []
        #if os(macOS)
        if includeAppleMail {
            result.append(
                WorkspaceConnection(
                    id: AppleMailEmailAdapter.connectionID,
                    kind: .appleMail,
                    displayName: "Apple Mail",
                    detail: "Local Mail.app store",
                    capabilities: .email,
                    isConnected: true
                )
            )
        }
        #endif
        result.append(
            WorkspaceConnection(
                id: eventKitCalendarConnectionID,
                kind: .eventKit,
                displayName: "On This Device",
                detail: "System calendars",
                capabilities: .calendar,
                isConnected: true
            )
        )
        for account in accountStore.accounts {
            result.append(
                WorkspaceConnection(
                    id: GoogleAuthAdapter.connectionID(for: account.id),
                    kind: .google,
                    displayName: account.label,
                    detail: account.detailedLabel,
                    capabilities: .emailAndCalendar,
                    isConnected: accountStore.isSignedIn(account)
                )
            )
        }
        for adapter in installedEmailAdapters {
            result.append(
                WorkspaceConnection(
                    id: adapter.connectionID,
                    kind: .preview,
                    displayName: adapter.displayName,
                    detail: "Test inbox",
                    capabilities: .email,
                    isConnected: adapter.isAvailable
                )
            )
        }
        return result
    }

    public var googleConnections: [WorkspaceConnection] {
        connections.filter { $0.kind == .google }
    }

    public var isOAuthConfigured: Bool { accountStore.isOAuthConfigured }

    /// Binds the live calendar cache/service so Google adapters can sync and
    /// `CalendarService` merges them into the Calendar tab.
    public func attach(
        calendarCache: any CalendarEventRepositoryProtocol,
        calendarService: CalendarService
    ) {
        self.calendarCache = calendarCache
        self.calendarService = calendarService
        pushCalendarProviders()
    }

    /// Email adapters for the unified inbox (Apple Mail + each signed-in Google account
    /// + any installed preview/test adapters).
    public func emailAdapters() -> [any EmailProviderAdapter] {
        let adapters = Self.emailAdapters(
            accountStore: accountStore,
            includeAppleMail: includeAppleMail,
            session: session
        ) + installedEmailAdapters.filter(\.isAvailable)
        ConnectionDebug.log(
            "ConnectionManager",
            "email adapters count=\(adapters.count) ids=\(adapters.map(\.connectionID).joined(separator: ","))"
        )
        return adapters
    }

    /// Registers an extra email adapter (tests / UI-test preview inbox).
    public func installEmailAdapter(_ adapter: any EmailProviderAdapter) {
        installedEmailAdapters.removeAll { $0.connectionID == adapter.connectionID }
        installedEmailAdapters.append(adapter)
        objectWillChange.send()
    }

    /// Loads three canned messages onto this manager for UI and integration tests.
    public func seedFakeInboxForTesting() {
        installEmailAdapter(FakeEmailProviderAdapter.sampleInbox())
    }

    /// Builds email adapters without going through the singleton (tests).
    public static func emailAdapters(
        accountStore: MailAccountStore,
        includeAppleMail: Bool,
        session: URLSession = .shared
    ) -> [any EmailProviderAdapter] {
        var adapters: [any EmailProviderAdapter] = []
        #if os(macOS)
        if includeAppleMail {
            adapters.append(AppleMailEmailAdapter())
        }
        #endif
        for account in accountStore.googleAccounts where accountStore.isSignedIn(account) {
            adapters.append(
                GoogleAuthAdapter(
                    account: account,
                    accountStore: accountStore,
                    session: session
                )
            )
        }
        return adapters
    }

    /// Calendar adapters for every signed-in Google account.
    public func calendarAdapters() -> [any CalendarProviderAdapter] {
        accountStore.googleAccounts.compactMap { account in
            guard accountStore.isSignedIn(account) else { return nil }
            return GoogleAuthAdapter(
                account: account,
                accountStore: accountStore,
                session: session,
                calendarCache: calendarCache
            )
        }
    }

    /// Interactive Google OAuth; persists the account and refreshes calendar adapters.
    @discardableResult
    public func connectGoogle(existing: MailAccount? = nil) async throws -> MailAccount {
        ConnectionDebug.log("ConnectionManager", "connect Google mode=\(existing == nil ? "add" : "reconnect")")
        let account = try await accountStore.authenticateAndPersistGoogleAccount(existing: existing)
        pushCalendarProviders()
        objectWillChange.send()
        ConnectionDebug.log(
            "ConnectionManager",
            "connect Google complete account=\(ConnectionDebug.account(account.id)) calendarProviders=\(calendarAdapters().count)"
        )
        return account
    }

    public func disconnect(id: String) {
        if id.hasPrefix("google:") {
            let accountID = String(id.dropFirst("google:".count))
            accountStore.removeAccount(id: accountID)
        }
        pushCalendarProviders()
        objectWillChange.send()
    }

    public func reconnectGoogle(_ account: MailAccount) async throws {
        _ = try await connectGoogle(existing: account)
    }

    private func pushCalendarProviders() {
        calendarService?.setProviders(calendarAdapters())
    }
}

private struct WorkspaceConnectionManagerKey: EnvironmentKey {
    static let defaultValue: WorkspaceConnectionManager? = nil
}

public extension EnvironmentValues {
    var workspaceConnectionManager: WorkspaceConnectionManager? {
        get { self[WorkspaceConnectionManagerKey.self] }
        set { self[WorkspaceConnectionManagerKey.self] = newValue }
    }
}
