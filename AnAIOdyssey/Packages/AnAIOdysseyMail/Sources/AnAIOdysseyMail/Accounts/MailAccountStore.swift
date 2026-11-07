// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import SwiftUI

/// Source of truth for the user's configured mail accounts (multi-account).
///
/// Persists account *metadata* (provider, email, id) as JSON in `UserDefaults`
/// (synced across devices via `CloudDefaultsSync`), while each account's OAuth
/// tokens live separately in the Keychain keyed by the account id. Provides
/// per-account `GoogleOAuthService`s and drives interactive Gmail sign-in.
///
/// The shared OAuth client id is stored once (Google issues one client per app)
/// and reused for every Google account.
@MainActor
public final class MailAccountStore: ObservableObject {
    /// `UserDefaults`/iCloud keys for persisted, non-secret values.
    private enum Keys {
        static let accounts = "anaiodyssey.mail.accounts"
        static let oauthClientID = GoogleOAuthService.oauthClientIDKey
    }

    /// The configured OAuth/IMAP accounts (Apple Mail is added by the reader on macOS).
    @Published public private(set) var accounts: [MailAccount] = []

    /// Shared Google OAuth client id (iOS or Desktop client); persisted on change.
    @Published public var oauthClientID: String {
        didSet { defaults.set(oauthClientID, forKey: Keys.oauthClientID) }
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let secureStore: TokenSecureStore
    private var tokenStores: [String: GoogleTokenStore] = [:]
    private var cloudSyncObserver: NSObjectProtocol?

    /// Loads persisted accounts and subscribes to iCloud-delivered changes.
    public convenience init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.init(defaults: defaults, session: session, secureStore: KeychainTokenSecureStore())
    }

    /// Designated initializer with an injectable secret backend (Keychain by default).
    init(defaults: UserDefaults = .standard, session: URLSession = .shared, secureStore: TokenSecureStore) {
        self.defaults = defaults
        self.session = session
        self.secureStore = secureStore
        self.oauthClientID = defaults.string(forKey: Keys.oauthClientID) ?? ""
        self.accounts = Self.loadAccounts(from: defaults)
        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: CloudDefaultsSync.didApplyRemoteChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDefaults() }
        }
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    /// True when a Google OAuth client id has been configured.
    public var isOAuthConfigured: Bool {
        !oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Gmail accounts among all configured accounts.
    public var googleAccounts: [MailAccount] {
        accounts.filter { $0.provider == .gmail }
    }

    /// A secure (Keychain-backed) token store scoped to `account`.
    ///
    /// Instances are reused so a successful in-memory save is visible to
    /// `isSignedIn` and the Email tab without requiring a second Keychain read.
    public func tokenStore(for account: MailAccount) -> GoogleTokenStore {
        if let existing = tokenStores[account.id] {
            ConnectionDebug.log("AccountStore", "reuse token store account=\(ConnectionDebug.account(account.id))")
            return existing
        }
        ConnectionDebug.log("AccountStore", "create token store account=\(ConnectionDebug.account(account.id))")
        let store = GoogleTokenStore(accountID: account.id, defaults: defaults, secureStore: secureStore)
        tokenStores[account.id] = store
        return store
    }

    /// An OAuth service bound to `account`'s token store and the shared client id.
    public func oauthService(for account: MailAccount) -> GoogleOAuthService {
        GoogleOAuthService(
            tokenStore: tokenStore(for: account),
            clientID: oauthClientID,
            defaults: defaults,
            session: session
        )
    }

    /// Whether `account` currently holds usable credentials (valid or refreshable token).
    public func isSignedIn(_ account: MailAccount) -> Bool {
        let store = tokenStore(for: account)
        guard store.tokens != nil else { return false }
        return store.hasValidAccessToken || store.refreshTokenValue() != nil
    }

    /// The first signed-in Google account, used for shared Google features (e.g. Calendar).
    public var primaryGoogleAccount: MailAccount? {
        googleAccounts.first { isSignedIn($0) } ?? googleAccounts.first
    }

    /// Interactively adds a Gmail account: runs OAuth, saves tokens, and persists it.
    ///
    /// If the resolved email matches an existing Gmail account, that account's
    /// tokens are refreshed in place instead of creating a duplicate.
    @discardableResult
    public func addGoogleAccount() async throws -> MailAccount {
        try await authenticateAndPersistGoogleAccount(existing: nil)
    }

    /// Re-runs interactive OAuth for an existing Gmail account, writing tokens
    /// into that account's Keychain slot (used when Google expired the login).
    @discardableResult
    public func reconnectGoogleAccount(_ account: MailAccount) async throws -> MailAccount {
        try await authenticateAndPersistGoogleAccount(existing: account)
    }

    /// One sign-in path: interactive Google auth, persist tokens, then account
    /// metadata. `existing` is the account to reconnect; `nil` adds one.
    @discardableResult
    public func authenticateAndPersistGoogleAccount(existing: MailAccount?) async throws -> MailAccount {
        guard isOAuthConfigured else { throw GoogleOAuthError.notConfigured }

        let target = existing ?? MailAccount(provider: .gmail, email: "")
        ConnectionDebug.log(
            "AccountStore",
            "authenticate start mode=\(existing == nil ? "add" : "reconnect") target=\(ConnectionDebug.account(target.id)) knownAccounts=\(googleAccounts.count)"
        )
        let oauth = oauthService(for: target)
        let hint = existing?.email.isEmpty == false ? existing?.email : nil
        let tokens = try await oauth.signInInteractively(loginHint: hint)
        try tokenStore(for: target).requirePersistedRefreshToken()
        ConnectionDebug.log(
            "AccountStore",
            "authentication tokens usable target=\(ConnectionDebug.account(target.id)) validAccess=\(tokenStore(for: target).hasValidAccessToken) hasRefresh=\(tokenStore(for: target).refreshTokenValue() != nil)"
        )

        let email = (try? await oauth.currentAccountEmail()) ?? existing?.email ?? ""
        ConnectionDebug.log(
            "AccountStore",
            "account identity resolved target=\(ConnectionDebug.account(target.id)) emailResolved=\(!email.isEmpty)"
        )

        if existing == nil, let match = googleAccounts.first(where: {
            !email.isEmpty && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) {
            try tokenStore(for: match).save(tokens)
            try tokenStore(for: match).requirePersistedRefreshToken()
            tokenStore(for: target).clear()
            tokenStores[target.id] = nil
            ConnectionDebug.log(
                "AccountStore",
                "merged authentication into existing account=\(ConnectionDebug.account(match.id)); cleared temporary=\(ConnectionDebug.account(target.id))"
            )
            return match
        }

        if let existing {
            if !email.isEmpty, email != existing.email,
               let index = accounts.firstIndex(where: { $0.id == existing.id }) {
                accounts[index].email = email
                persist()
                ConnectionDebug.log("AccountStore", "reconnect complete account=\(ConnectionDebug.account(existing.id)) emailUpdated=true")
                return accounts[index]
            }
            ConnectionDebug.log("AccountStore", "reconnect complete account=\(ConnectionDebug.account(existing.id)) emailUpdated=false")
            return existing
        }

        let account = MailAccount(id: target.id, provider: .gmail, email: email)
        accounts.append(account)
        persist()
        ConnectionDebug.log("AccountStore", "account added account=\(ConnectionDebug.account(account.id)) total=\(accounts.count)")
        return account
    }

    /// Removes an account from the list and deletes its Keychain tokens.
    public func removeAccount(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        tokenStore(for: account).clear()
        tokenStores[id] = nil
        accounts.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    /// Writes the current account list to `UserDefaults` as JSON.
    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
    }

    /// Re-reads accounts and client id after iCloud applies remote changes.
    ///
    /// Incoming account lists are merged with local ones so a just-authenticated
    /// account (and its Keychain tokens) is not replaced by a stale iCloud snapshot.
    private func reloadFromDefaults() {
        let incoming = Self.loadAccounts(from: defaults)
        let merged = mergingIncomingAccounts(incoming)
        if merged != accounts {
            accounts = merged
            persist()
        }
        let newClientID = defaults.string(forKey: Keys.oauthClientID) ?? ""
        if newClientID != oauthClientID { oauthClientID = newClientID }
    }

    /// Prefers locally signed-in accounts (tokens live in this device's Keychain)
    /// and unions in any other accounts from iCloud.
    func mergingIncomingAccounts(_ incoming: [MailAccount]) -> [MailAccount] {
        var result: [MailAccount] = []
        var claimedIDs = Set<String>()
        var claimedEmails = Set<String>()

        func claim(_ account: MailAccount) {
            guard !claimedIDs.contains(account.id) else { return }
            let email = account.email.lowercased()
            if !email.isEmpty, claimedEmails.contains(email) { return }
            result.append(account)
            claimedIDs.insert(account.id)
            if !email.isEmpty { claimedEmails.insert(email) }
        }

        for account in accounts where isSignedIn(account) {
            claim(account)
        }
        for account in incoming {
            claim(account)
        }
        for account in accounts {
            claim(account)
        }
        return result
    }

    /// Decodes the persisted account list, returning an empty list if absent/corrupt.
    private static func loadAccounts(from defaults: UserDefaults) -> [MailAccount] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let decoded = try? JSONDecoder().decode([MailAccount].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// SwiftUI environment key exposing the `MailAccountStore` to views.
private struct MailAccountStoreKey: EnvironmentKey {
    static let defaultValue: MailAccountStore? = nil
}

public extension EnvironmentValues {
    /// Access the app's `MailAccountStore` via `@Environment(\.mailAccountStore)`.
    var mailAccountStore: MailAccountStore? {
        get { self[MailAccountStoreKey.self] }
        set { self[MailAccountStoreKey.self] = newValue }
    }
}
