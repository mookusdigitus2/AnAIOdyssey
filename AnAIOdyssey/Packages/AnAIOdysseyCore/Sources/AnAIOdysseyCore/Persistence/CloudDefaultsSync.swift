// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Mirrors selected `UserDefaults` configuration keys to iCloud key-value storage
/// (`NSUbiquitousKeyValueStore`) so settings and configuration stay in sync across
/// a user's devices (e.g. Mac and iPad).
///
/// SwiftData/CloudKit handles the user's *data*; this handles the small set of
/// *configuration* values that live in `UserDefaults`.
public final class CloudDefaultsSync {
    public static let shared = CloudDefaultsSync()

    /// Posted on the main queue after remote (iCloud) changes have been written
    /// into local `UserDefaults`. Settings objects can observe this to reload.
    public static let didApplyRemoteChanges = Notification.Name("AnAIOdysseyCore.CloudDefaultsSync.didApplyRemoteChanges")

    // Lazy so `NSUbiquitousKeyValueStore.default` is never touched on builds
    // without a valid iCloud key-value-store entitlement (Simulator/teamless),
    // where its XPC machinery can crash.
    private lazy var kvStore = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard

    /// Only keys with this prefix are considered for syncing.
    private let syncedPrefix = "anaiodyssey."

    /// Keys we deliberately keep device-local or out of iCloud:
    /// - `oauthTokens`: OAuth refresh/access tokens (sensitive, refresh races).
    /// - `anaiodyssey.task.`: per-device scheduling / notification identifiers.
    /// - `anaiodyssey.remote.`: remote LLM API keys and connection secrets (Keychain-only).
    private let excludedSubstrings = ["oauthTokens", "anaiodyssey.task.", "anaiodyssey.remote."]

    private var isApplyingRemoteChange = false
    private var started = false

    private init() {}

    /// Begins syncing. Call once, as early as possible at launch (before
    /// settings objects read `UserDefaults`).
    public func start() {
        guard !started else { return }
        DefaultsKeyMigration.migrate(defaults: defaults)
        // Only sync through iCloud when it's actually available. Without a valid
        // iCloud key-value-store entitlement (e.g. unsigned/teamless builds or
        // the Simulator with no iCloud account), touching NSUbiquitousKeyValueStore
        // can crash in its XPC layer, so we skip syncing entirely and rely on
        // local UserDefaults.
        guard ICloudAvailability.isAvailable else { return }
        started = true

        // React to changes pushed from other devices via iCloud.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] note in
            self?.ubiquitousStoreChanged(note)
        }

        // React to local edits so they get pushed up to iCloud.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.localDefaultsChanged()
        }

        // Perform an initial two-way reconcile: pull remote values down, then
        // push any local-only values up.
        kvStore.synchronize()
        DefaultsKeyMigration.migrateCloudStore(kvStore)
        applyCloudToLocal(keys: cloudSyncedKeys())
        pushLocalToCloud()
    }

    /// Whether a given key is eligible for syncing (has the synced prefix and is
    /// not on the device-local exclusion list).
    private func shouldSync(_ key: String) -> Bool {
        guard key.hasPrefix(syncedPrefix) else { return false }
        return !excludedSubstrings.contains { key.contains($0) }
    }

    /// The syncable keys currently present in the iCloud key-value store.
    private func cloudSyncedKeys() -> [String] {
        kvStore.dictionaryRepresentation.keys.filter { shouldSync($0) }
    }

    /// Copies the given iCloud values down into local `UserDefaults` and notifies
    /// observers.
    ///
    /// Guards re-entrancy with `isApplyingRemoteChange` so the resulting
    /// `UserDefaults.didChange` notification doesn't immediately push the same
    /// values back up.
    private func applyCloudToLocal(keys: [String]) {
        guard !keys.isEmpty else { return }
        // Suppress the echo: mark that the upcoming local writes originate from iCloud.
        isApplyingRemoteChange = true
        for key in keys {
            defaults.set(kvStore.object(forKey: key), forKey: key)
        }
        isApplyingRemoteChange = false
        NotificationCenter.default.post(name: Self.didApplyRemoteChanges, object: nil)
    }

    /// Pushes syncable local `UserDefaults` values up to iCloud, writing only the
    /// ones that actually differ to avoid needless sync churn.
    private func pushLocalToCloud() {
        var changed = false
        for (key, value) in defaults.dictionaryRepresentation() where shouldSync(key) {
            // Only write keys whose value diverges from what iCloud already holds.
            let existing = kvStore.object(forKey: key)
            if !valuesAreEqual(existing, value) {
                kvStore.set(value, forKey: key)
                changed = true
            }
        }
        if changed { kvStore.synchronize() }
    }

    /// Compares two `UserDefaults`/KVS values for equality, treating both-nil as
    /// equal and bridging through `NSObject.isEqual` for the boxed plist types.
    private func valuesAreEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l as NSObject, r as NSObject):
            return l.isEqual(r)
        default:
            return false
        }
    }

    /// Handles an external (iCloud) change notification by applying just the
    /// changed syncable keys, or all of them when the notification omits the list.
    private func ubiquitousStoreChanged(_ note: Notification) {
        let changedKeys: [String]
        // Prefer the precise set of changed keys; fall back to a full reconcile.
        if let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            changedKeys = keys.filter { shouldSync($0) }
        } else {
            changedKeys = cloudSyncedKeys()
        }
        applyCloudToLocal(keys: changedKeys)
    }

    /// Handles a local `UserDefaults` change by pushing it to iCloud — unless the
    /// change was one we just applied *from* iCloud (avoids a feedback loop).
    private func localDefaultsChanged() {
        guard !isApplyingRemoteChange else { return }
        pushLocalToCloud()
    }
}
