// SPDX-License-Identifier: MIT
import Foundation
import Security

/// Low-level Keychain helpers for storing small secrets outside UserDefaults.
///
/// Items are written to the data-protection keychain (`kSecUseDataProtectionKeychain`)
/// so macOS does not attach a login-keychain ACL. The file-based keychain prompts
/// "allow access" on every launch of a rebuilt/debug binary, which then looks like
/// the secret was lost. Reads fall back to that older store and migrate on success.
public enum KeychainStore {
    public static let remoteAPIKeyService = "com.example.anaiodyssey.remote.apiKeys"
    /// Service name used by pre-rename builds; items are copied on first read.
    public static let legacyRemoteAPIKeyService = "com.odysseus.remote.apiKeys"

    @discardableResult
    public static func set(_ data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account, dataProtection: true)
        var query = baseQuery(service: service, account: account, dataProtection: true)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func get(service: String, account: String) -> Data? {
        // Diagnostic escape hatch: differently-signed builds (debug vs TestFlight)
        // trigger blocking keychain permission prompts for each other's items.
        if ProcessInfo.processInfo.environment["ANAIODYSSEY_SKIP_KEYCHAIN"] == "1" { return nil }
        if let data = copyMatching(service: service, account: account, dataProtection: true) {
            return data
        }
        // Only macOS has a separate legacy keychain; on iOS this would delete
        // the item `set` just wrote.
        #if os(macOS)
        if let data = copyMatching(service: service, account: account, dataProtection: false) {
            _ = set(data, service: service, account: account)
            delete(service: service, account: account, dataProtection: false)
            return data
        }
        #endif
        guard service == remoteAPIKeyService,
              let data = get(service: legacyRemoteAPIKeyService, account: account) else {
            return nil
        }
        _ = set(data, service: service, account: account)
        return data
    }

    public static func delete(service: String, account: String) {
        delete(service: service, account: account, dataProtection: true)
        delete(service: service, account: account, dataProtection: false)
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

/// Pluggable secret backend for token/API-key storage.
public protocol TokenSecureStore: AnyObject {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String)
    func remove(account: String)
}

/// Keychain-backed store used in production builds.
public final class KeychainTokenSecureStore: TokenSecureStore {
    private let service: String

    public init(service: String = KeychainStore.remoteAPIKeyService) {
        self.service = service
    }

    public func read(account: String) -> Data? {
        KeychainStore.get(service: service, account: account)
    }

    public func write(_ data: Data, account: String) {
        KeychainStore.set(data, service: service, account: account)
    }

    public func remove(account: String) {
        KeychainStore.delete(service: service, account: account)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryTokenSecureStore: TokenSecureStore {
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(account: String) -> Data? { storage[account] }
    public func write(_ data: Data, account: String) { storage[account] = data }
    public func remove(account: String) { storage[account] = nil }
}
