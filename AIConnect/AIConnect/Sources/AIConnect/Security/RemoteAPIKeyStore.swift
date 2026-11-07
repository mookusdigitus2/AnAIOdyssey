// SPDX-License-Identifier: MIT
import Foundation

/// Persists remote LLM API keys in the Keychain, keyed by connection id.
///
/// Connection metadata (without secrets) lives in UserDefaults; each connection's
/// `apiKey` is stored here under `connection.<id>`. Legacy plaintext keys in
/// UserDefaults are migrated on first access.
public final class RemoteAPIKeyStore {
    private enum LegacyKeys {
        static let apiKey = "anaiodyssey.remote.apiKey"
        static let connections = "anaiodyssey.remote.connections"
        static let previousApiKey = "odysseus.remote.apiKey"
        static let previousConnections = "odysseus.remote.connections"
    }

    private let defaults: UserDefaults
    private let secureStore: TokenSecureStore
    private var migrated = false

    public init(defaults: UserDefaults = .standard, secureStore: TokenSecureStore = KeychainTokenSecureStore()) {
        self.defaults = defaults
        self.secureStore = secureStore
    }

    private func accountKey(for connectionID: String) -> String {
        "connection.\(connectionID)"
    }

    /// Reads the API key for a connection from the Keychain.
    public func apiKey(for connectionID: String) -> String {
        migrateLegacyKeysIfNeeded()
        guard let data = secureStore.read(account: accountKey(for: connectionID)),
              let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }

    /// Writes an API key for a connection into the Keychain.
    public func setAPIKey(_ key: String, for connectionID: String) {
        migrateLegacyKeysIfNeeded()
        let account = accountKey(for: connectionID)
        if key.isEmpty {
            secureStore.remove(account: account)
        } else if let data = key.data(using: .utf8) {
            secureStore.write(data, account: account)
        }
    }

    /// Removes a connection's stored key.
    public func removeAPIKey(for connectionID: String) {
        secureStore.remove(account: accountKey(for: connectionID))
    }

    /// One-time migration from plaintext UserDefaults / embedded JSON keys.
    public func migrateLegacyKeysIfNeeded() {
        guard !migrated else { return }
        migrated = true

        // Legacy single-provider key → primary connection slot.
        for key in [LegacyKeys.apiKey, LegacyKeys.previousApiKey] {
            if let legacyKey = defaults.string(forKey: key), !legacyKey.isEmpty {
                if apiKey(for: "legacy-remote").isEmpty {
                    setAPIKey(legacyKey, for: "legacy-remote")
                }
                defaults.removeObject(forKey: key)
            }
        }

        // Keys embedded in the connections JSON blob.
        for key in [LegacyKeys.connections, LegacyKeys.previousConnections] {
            if let data = defaults.data(forKey: key),
               var connections = try? JSONDecoder().decode([LegacyConnection].self, from: data) {
                var changed = false
                for index in connections.indices {
                    let embedded = connections[index].apiKey
                    guard !embedded.isEmpty else { continue }
                    if apiKey(for: connections[index].id).isEmpty {
                        setAPIKey(embedded, for: connections[index].id)
                    }
                    if connections[index].apiKey != "" {
                        connections[index].apiKey = ""
                        changed = true
                    }
                }
                if changed, let stripped = try? JSONEncoder().encode(connections) {
                    defaults.set(stripped, forKey: LegacyKeys.connections)
                }
                if key != LegacyKeys.connections {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    private struct LegacyConnection: Codable {
        var id: String
        var apiKey: String
    }
}
