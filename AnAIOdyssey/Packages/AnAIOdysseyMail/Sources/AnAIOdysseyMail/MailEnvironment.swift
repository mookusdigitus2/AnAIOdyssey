// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftUI

/// SwiftUI environment key that carries the active mail reader down the view tree.
/// Defaults to `nil` so views can detect when no backend has been injected.
private struct MailReaderServiceKey: EnvironmentKey {
    static let defaultValue: (any MailReaderServiceProtocol)? = nil
}

public extension EnvironmentValues {
    /// The mail reader available to SwiftUI views via `@Environment(\.mailReader)`.
    var mailReader: (any MailReaderServiceProtocol)? {
        get { self[MailReaderServiceKey.self] }
        set { self[MailReaderServiceKey.self] = newValue }
    }

    /// Sends outgoing mail through configured Gmail accounts.
    var mailSendService: MailSendService? {
        get { self[MailSendServiceKey.self] }
        set { self[MailSendServiceKey.self] = newValue }
    }
}

private struct MailSendServiceKey: EnvironmentKey {
    static let defaultValue: MailSendService? = nil
}

#if os(macOS)
import AppKit

/// macOS-only helpers for guiding the user through Apple Mail privacy permissions.
///
/// Reading Apple Mail's local store requires Full Disk Access, which can only be
/// granted in System Settings. This type is gated to macOS because the deep-link
/// and `NSWorkspace` APIs don't exist on iOS.
public enum MailPermissionSupport {
    /// Opens System Settings directly to the Full Disk Access privacy pane.
    public static func openFullDiskAccessSettings() {
        // Deep-link straight to Privacy & Security > Full Disk Access so the user
        // can grant the app access without hunting through settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
