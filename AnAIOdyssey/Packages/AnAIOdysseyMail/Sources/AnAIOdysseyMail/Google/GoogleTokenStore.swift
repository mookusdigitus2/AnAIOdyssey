// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// The set of Google OAuth tokens persisted between launches.
///
/// `Codable` so it can be serialized into the Keychain. `expiresAt` is optional because
/// some flows omit an expiry; `refreshToken` may be absent on refresh responses (Google
/// only returns it once at initial consent).
public struct GoogleOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }

    /// Whether the access token is expired (or within a 60s safety margin of expiring).
    ///
    /// The 60-second skew avoids using a token that may lapse mid-request; tokens with no
    /// known expiry are treated as not expired.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(60)
    }
}

/// Serializes token refreshes for one account so concurrent callers (Gmail
/// message list/detail fetches, Calendar sync) share a single refresh grant
/// instead of racing Google with the same refresh token.
actor TokenRefreshGate {
    private var inFlight: Task<GoogleOAuthTokens, Error>?

    /// Runs `work`, or joins an already in-flight refresh and returns its result.
    func run(_ work: @escaping () async throws -> GoogleOAuthTokens) async throws -> GoogleOAuthTokens {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Persists Google OAuth tokens in the Keychain, namespaced per account.
///
/// Each store is scoped to a `accountID` (a ``MailAccount/id`` or the legacy
/// `"primary"` slot) and reads/writes the encoded tokens JSON from the Keychain
/// under that account key. If the Keychain write fails, tokens stay in memory
/// and in a local `UserDefaults` key containing `oauthTokens` (excluded from
/// iCloud). A decoded copy is cached in memory to avoid repeated reads.
///
/// On first use of the legacy `"primary"` slot it migrates any tokens previously
/// stored under the old `UserDefaults` key into the Keychain, then removes the
/// plaintext copy.
public final class GoogleTokenStore {
    /// Legacy `UserDefaults` key that older builds used to store the encoded tokens JSON.
    private enum LegacyKeys {
        static let tokensJSON = "anaiodyssey.google.oauthTokens"
        static let previousTokensJSON = "odysseus.google.oauthTokens"
    }

    /// Default account slot used by single-account callers and back-compat code paths.
    public static let primaryAccountID = "primary"

    /// The account namespace this store reads/writes (Keychain account key).
    public let accountID: String
    private let defaults: UserDefaults
    private let secureStore: TokenSecureStore
    private var cachedTokens: GoogleOAuthTokens?
    /// Single-flight gate shared by every `GoogleOAuthService` bound to this
    /// store (the account's Gmail reader and Calendar client each hold one).
    private let refreshGate = TokenRefreshGate()

    /// Back-compat initializer used by single-account callers; binds to the primary slot.
    ///
    /// The `defaults` parameter is retained only to migrate any legacy plaintext
    /// tokens into the Keychain on first load.
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(accountID: Self.primaryAccountID, defaults: defaults)
    }

    /// Creates a store scoped to a specific account and eagerly loads its tokens.
    public convenience init(accountID: String, defaults: UserDefaults = .standard) {
        self.init(accountID: accountID, defaults: defaults, secureStore: KeychainTokenSecureStore())
    }

    /// Designated initializer with an injectable secure backend (Keychain by default).
    init(accountID: String, defaults: UserDefaults = .standard, secureStore: TokenSecureStore) {
        self.accountID = accountID
        self.defaults = defaults
        self.secureStore = secureStore
        migrateLegacyTokensIfNeeded()
        loadCachedTokens()
        ConnectionDebug.log(
            "TokenStore",
            "initialized account=\(ConnectionDebug.account(accountID)) hasAccess=\(cachedTokens?.accessToken.isEmpty == false) hasRefresh=\(cachedTokens?.refreshToken?.isEmpty == false) expired=\(cachedTokens?.isExpired ?? true)"
        )
    }

    /// The currently cached tokens, if any.
    public var tokens: GoogleOAuthTokens? {
        cachedTokens
    }

    /// True only when a non-empty, unexpired access token is held.
    public var hasValidAccessToken: Bool {
        guard let tokens = cachedTokens, !tokens.accessToken.isEmpty else { return false }
        return !tokens.isExpired
    }

    /// Caches tokens in memory, then persists them to the Keychain (with a
    /// local `UserDefaults` fallback the iCloud syncer excludes).
    ///
    /// Sign-in must succeed for the current session even when Keychain write
    /// fails; the fallback keeps the same tokens across relaunch.
    public func save(_ tokens: GoogleOAuthTokens) throws {
        ConnectionDebug.log(
            "TokenStore",
            "save start account=\(ConnectionDebug.account(accountID)) hasAccess=\(!tokens.accessToken.isEmpty) hasRefresh=\(tokens.refreshToken?.isEmpty == false) expiresAt=\(tokens.expiresAt?.description ?? "nil")"
        )
        guard !tokens.accessToken.isEmpty else {
            throw GoogleOAuthError.tokenPersistFailed("Google did not return an access token.")
        }
        var tokens = tokens
        // Google omits refresh_token on some repeat grants; never let that erase
        // the long-lived credential already held for this account.
        if tokens.refreshToken?.nilIfEmpty == nil {
            tokens.refreshToken = refreshTokenValue() ?? readPersistedTokens()?.refreshToken?.nilIfEmpty
        }
        guard let data = try? JSONEncoder().encode(tokens) else {
            throw GoogleOAuthError.tokenPersistFailed("Could not encode Google sign-in tokens.")
        }
        cachedTokens = tokens
        if persistToSecureStore(data, expectedAccessToken: tokens.accessToken) {
            defaults.removeObject(forKey: fallbackDefaultsKey)
            ConnectionDebug.log(
                "TokenStore",
                "save complete account=\(ConnectionDebug.account(accountID)) destination=keychain hasRefresh=\(tokens.refreshToken?.isEmpty == false)"
            )
            return
        }
        defaults.set(data, forKey: fallbackDefaultsKey)
        ConnectionDebug.log(
            "TokenStore",
            "save complete account=\(ConnectionDebug.account(accountID)) destination=local-fallback hasRefresh=\(tokens.refreshToken?.isEmpty == false)"
        )
    }

    /// Throws unless this store holds a usable access token or a refresh token.
    ///
    /// Google sometimes omits `refresh_token` on a repeat consent; that must not
    /// abort a successful sign-in that already issued an access token.
    public func requirePersistedRefreshToken() throws {
        if cachedTokens == nil {
            loadCachedTokens()
        }
        ConnectionDebug.log(
            "TokenStore",
            "validate account=\(ConnectionDebug.account(accountID)) validAccess=\(hasValidAccessToken) hasRefresh=\(refreshTokenValue() != nil)"
        )
        guard hasValidAccessToken || refreshTokenValue() != nil else {
            throw GoogleOAuthError.tokenPersistFailed(
                "Google sign-in did not produce usable tokens. Sign in again."
            )
        }
    }

    /// Runs `work` through this store's single-flight refresh gate so concurrent
    /// refreshes for the same account share one grant instead of racing.
    func coordinateRefresh(_ work: @escaping () async throws -> GoogleOAuthTokens) async throws -> GoogleOAuthTokens {
        try await refreshGate.run(work)
    }

    /// Clears tokens from memory, the secure store, and the local fallback.
    public func clear() {
        ConnectionDebug.log("TokenStore", "clear account=\(ConnectionDebug.account(accountID))")
        cachedTokens = nil
        secureStore.remove(account: accountID)
        defaults.removeObject(forKey: fallbackDefaultsKey)
    }

    /// Returns the current access token if present and non-empty (caller decides on refresh).
    public func accessTokenNeedingRefresh() -> String? {
        cachedTokens?.accessToken.nilIfEmpty
    }

    /// Returns the refresh token if present and non-empty.
    public func refreshTokenValue() -> String? {
        cachedTokens?.refreshToken?.nilIfEmpty
    }

    /// Local-only fallback key; the `oauthTokens` substring keeps it out of iCloud KVS.
    private var fallbackDefaultsKey: String {
        "anaiodyssey.google.oauthTokens.\(accountID)"
    }

    /// Writes to the Keychain and confirms the same access token reads back.
    private func persistToSecureStore(_ data: Data, expectedAccessToken: String) -> Bool {
        guard secureStore.write(data, account: accountID) else {
            ConnectionDebug.log("TokenStore", "keychain write failed account=\(ConnectionDebug.account(accountID))")
            return false
        }
        guard let stored = secureStore.read(account: accountID),
              let decoded = try? JSONDecoder().decode(GoogleOAuthTokens.self, from: stored),
              decoded.accessToken == expectedAccessToken else {
            ConnectionDebug.log("TokenStore", "keychain verification failed account=\(ConnectionDebug.account(accountID))")
            return false
        }
        cachedTokens = decoded
        return true
    }

    /// Loads persisted tokens (Keychain, then local fallback) without wiping a live cache.
    private func loadCachedTokens() {
        if let decoded = readPersistedTokens() {
            cachedTokens = decoded
        }
    }

    /// Decodes tokens from the Keychain or the local UserDefaults fallback.
    private func readPersistedTokens() -> GoogleOAuthTokens? {
        if let data = secureStore.read(account: accountID),
           let decoded = try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data) {
            ConnectionDebug.log("TokenStore", "loaded account=\(ConnectionDebug.account(accountID)) source=keychain")
            return decoded
        }
        if let data = defaults.data(forKey: fallbackDefaultsKey),
           let decoded = try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data) {
            ConnectionDebug.log("TokenStore", "loaded account=\(ConnectionDebug.account(accountID)) source=local-fallback")
            return decoded
        }
        ConnectionDebug.log("TokenStore", "no persisted tokens account=\(ConnectionDebug.account(accountID))")
        return nil
    }

    /// One-time migration of legacy plaintext tokens (primary slot only) into the secure store.
    private func migrateLegacyTokensIfNeeded() {
        guard accountID == Self.primaryAccountID else { return }
        // Nothing to migrate if the secure store already holds tokens for this slot.
        if secureStore.read(account: accountID) != nil {
            return
        }
        guard let data = defaults.data(forKey: LegacyKeys.tokensJSON)
                ?? defaults.data(forKey: LegacyKeys.previousTokensJSON) else { return }
        if !(secureStore.write(data, account: accountID) && secureStore.read(account: accountID) != nil) {
            defaults.set(data, forKey: fallbackDefaultsKey)
        }
        defaults.removeObject(forKey: LegacyKeys.tokensJSON)
        defaults.removeObject(forKey: LegacyKeys.previousTokensJSON)
    }
}

private extension String {
    /// Returns `nil` for an empty string, otherwise the string itself.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
