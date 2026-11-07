// SPDX-License-Identifier: MIT
import Foundation

/// Settings changes that arrive from outside the process. Apps that sync
/// settings (for example over iCloud) post this after writing new values so the
/// connection settings reload. The name matches An AI Odyssey's sync notice.
public enum AIConnectSync {
    public static let settingsChangedExternally = Notification.Name("AnAIOdysseyCore.CloudDefaultsSync.didApplyRemoteChanges")
}

/// The host app's name, for sign-in pages and request headers.
public enum AIConnectBranding {
    public static var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
    }
}
