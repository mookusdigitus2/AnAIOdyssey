// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIConnect

/// Empties local configuration for the screenshot UI test only.
///
/// Normal launches never call ``prepare()``. The test passes `UITEST_CONFIG_SHOTS`
/// and also skips `CloudDefaultsSync`, so iCloud key-value storage is neither
/// read nor written during the capture. A later normal launch still pulls
/// synced values down before pushing local ones.
public enum ConfigScreenshotIsolation {
    public static let launchArgument = "UITEST_CONFIG_SHOTS"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Drops app configuration from this process's `UserDefaults` and the
    /// legacy remote-key slot. Call before any settings object is created.
    public static func prepare() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        let preserved = "anaiodyssey.setup.completed"
        for key in defaults.dictionaryRepresentation().keys where key != preserved {
            if key.hasPrefix("anaiodyssey.") || key.hasPrefix("odysseus.") {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: preserved)
        // `KeychainStore.get` copies the pre-rename item into the current
        // service on read, so both slots have to be gone before settings load.
        for service in [KeychainStore.remoteAPIKeyService, KeychainStore.legacyRemoteAPIKeyService] {
            KeychainStore.delete(service: service, account: "connection.legacy-remote")
        }
    }
}
