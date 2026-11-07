// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Copies pre-rename `UserDefaults` / iCloud KVS keys onto the current
/// `anaiodyssey.` prefix so settings survive the product rename.
public enum DefaultsKeyMigration {
    /// Rewrites keys in `defaults` from `legacyDefaultsKeyPrefix` to
    /// `defaultsKeyPrefix`. Existing destination keys are left unchanged.
    public static func migrate(defaults: UserDefaults = .standard) {
        migrate(
            keysAndValues: defaults.dictionaryRepresentation(),
            set: { defaults.set($0, forKey: $1) },
            remove: { defaults.removeObject(forKey: $0) }
        )
    }

    /// Same rewrite for iCloud key-value storage. Call only when iCloud KVS is
    /// actually available — touching the store without an entitlement can crash.
    public static func migrateCloudStore(_ store: NSUbiquitousKeyValueStore) {
        var changed = false
        migrate(
            keysAndValues: store.dictionaryRepresentation,
            set: { value, key in
                store.set(value, forKey: key)
                changed = true
            },
            remove: { key in
                store.removeObject(forKey: key)
                changed = true
            }
        )
        if changed {
            store.synchronize()
        }
    }

    private static func migrate(
        keysAndValues: [String: Any],
        set: (Any, String) -> Void,
        remove: (String) -> Void
    ) {
        let sourcePrefix = AppBranding.legacyDefaultsKeyPrefix
        let destPrefix = AppBranding.defaultsKeyPrefix
        for (key, value) in keysAndValues where key.hasPrefix(sourcePrefix) {
            let newKey = destPrefix + key.dropFirst(sourcePrefix.count)
            if keysAndValues[newKey] == nil {
                set(value, newKey)
            }
            remove(key)
        }
    }
}
