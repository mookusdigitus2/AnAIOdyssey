// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Security

/// A tiny wrapper over the Keychain (`kSecClassGenericPassword`) for storing
/// small secrets — here, per-account OAuth token blobs.
///
/// Secrets are namespaced by a fixed `service` plus a caller-supplied `account`
/// key (the `MailAccount.id`). Using the Keychain instead of `UserDefaults`
/// keeps OAuth refresh/access tokens out of plaintext defaults and excludes them
/// from iCloud key-value sync. Items go in the data-protection keychain so macOS
/// does not attach a login-keychain ACL (those ACLs prompt on every rebuilt
/// debug binary and look like a lost Google login).
enum KeychainStore {
    /// Default service namespace for Google OAuth token blobs.
    static let googleTokenService = "com.example.anaiodyssey.google.oauthTokens"
    /// Service name used by pre-rename builds; items are copied on first read.
    static let legacyGoogleTokenService = "com.odysseus.google.oauthTokens"

    /// Stores `data` under (`service`, `account`), replacing any existing item.
    /// Prefers the data-protection keychain; if that add fails (unsigned debug
    /// binaries, missing entitlement), falls back to the legacy keychain so
    /// Google sign-in still persists.
    /// Only macOS has a separate file-based (legacy) keychain. On iOS a query
    /// without `kSecUseDataProtectionKeychain` hits the SAME item, so the
    /// "remove the legacy copy" step deleted the token we had just written and
    /// TokenStore's verify read failed ("keychain verification failed",
    /// destination=local-fallback).
    static var hasSeparateLegacyKeychain: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        if addOrUpdate(data, service: service, account: account, dataProtection: true) {
            if hasSeparateLegacyKeychain {
                delete(service: service, account: account, dataProtection: false)
            }
            return true
        }
        return addOrUpdate(data, service: service, account: account, dataProtection: false)
    }

    /// Reads the data stored under (`service`, `account`), or `nil` if absent.
    static func get(service: String, account: String) -> Data? {
        // Diagnostic escape hatch: differently-signed builds (debug vs TestFlight)
        // trigger blocking keychain permission prompts for each other's items.
        if ProcessInfo.processInfo.environment["ANAIODYSSEY_SKIP_KEYCHAIN"] == "1" { return nil }
        if let data = copyMatching(service: service, account: account, dataProtection: true) {
            return data
        }
        if hasSeparateLegacyKeychain,
           let data = copyMatching(service: service, account: account, dataProtection: false) {
            // Migrate only if the data-protection write succeeds; never delete the
            // only copy when that write fails.
            if addOrUpdate(data, service: service, account: account, dataProtection: true) {
                delete(service: service, account: account, dataProtection: false)
            }
            return data
        }
        guard service == googleTokenService,
              let data = get(service: legacyGoogleTokenService, account: account) else {
            return nil
        }
        _ = set(data, service: service, account: account)
        return data
    }

    /// Removes the item under (`service`, `account`); a no-op if it doesn't exist.
    static func delete(service: String, account: String) {
        delete(service: service, account: account, dataProtection: true)
        delete(service: service, account: account, dataProtection: false)
    }

    /// Adds a new item, or updates it when a duplicate already exists.
    private static func addOrUpdate(
        _ data: Data,
        service: String,
        account: String,
        dataProtection: Bool
    ) -> Bool {
        var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        let updateQuery = baseQuery(service: service, account: account, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    private static func copyMatching(service: String, account: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func delete(service: String, account: String, dataProtection: Bool) {
        let query = baseQuery(service: service, account: account, dataProtection: dataProtection)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(service: String, account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

/// Pluggable secret backend for token storage, so the app can use the Keychain
/// while tests use an in-memory store (avoiding Keychain entitlement issues in
/// unsigned test binaries).
protocol TokenSecureStore: AnyObject {
    func read(account: String) -> Data?
    @discardableResult
    func write(_ data: Data, account: String) -> Bool
    func remove(account: String)
}

/// Keychain-backed `TokenSecureStore` used by the app.
final class KeychainTokenSecureStore: TokenSecureStore {
    private let service: String

    init(service: String = KeychainStore.googleTokenService) {
        self.service = service
    }

    func read(account: String) -> Data? {
        KeychainStore.get(service: service, account: account)
    }

    @discardableResult
    func write(_ data: Data, account: String) -> Bool {
        KeychainStore.set(data, service: service, account: account)
    }

    func remove(account: String) {
        KeychainStore.delete(service: service, account: account)
    }
}

/// In-memory `TokenSecureStore` for tests and previews.
final class InMemoryTokenSecureStore: TokenSecureStore {
    private var storage: [String: Data] = [:]

    func read(account: String) -> Data? { storage[account] }
    @discardableResult
    func write(_ data: Data, account: String) -> Bool {
        storage[account] = data
        return true
    }
    func remove(account: String) { storage[account] = nil }
}
