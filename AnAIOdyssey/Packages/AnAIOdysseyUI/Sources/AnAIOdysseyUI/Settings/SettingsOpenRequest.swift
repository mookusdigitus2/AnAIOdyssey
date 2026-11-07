// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Opens Settings to a specific page (used by Chat "Turn On" and the quick-facts line).
public enum SettingsOpenFocus: String, Sendable, Hashable {
    case braveSearchKey
}

public enum SettingsOpenRequest {
    public static let notification = Notification.Name("anaiodyssey.settings.open")
    public static let pageKey = "page"
    public static let focusKey = "focus"
    public static let connectionIDKey = "connectionID"

    public static func post(page: SettingsPage, focus: SettingsOpenFocus? = nil, connectionID: String? = nil) {
        var info: [String: String] = [pageKey: page.rawValue]
        if let focus {
            info[focusKey] = focus.rawValue
        }
        if let connectionID, !connectionID.isEmpty {
            info[connectionIDKey] = connectionID
        }
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: info
        )
    }

    public static func page(from notification: Notification) -> SettingsPage? {
        guard let raw = notification.userInfo?[pageKey] as? String else { return nil }
        return SettingsPage(rawValue: raw)
    }

    public static func focus(from notification: Notification) -> SettingsOpenFocus? {
        guard let raw = notification.userInfo?[focusKey] as? String else { return nil }
        return SettingsOpenFocus(rawValue: raw)
    }

    public static func connectionID(from notification: Notification) -> String? {
        guard let raw = notification.userInfo?[connectionIDKey] as? String,
              !raw.isEmpty else { return nil }
        return raw
    }
}
