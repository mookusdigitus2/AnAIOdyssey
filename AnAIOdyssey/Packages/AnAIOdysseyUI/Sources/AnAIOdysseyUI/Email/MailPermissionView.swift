// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import AnAIOdysseyMail
import SwiftUI

#if os(macOS)
/// Permission gate shown when Apple Mail access is denied: explains Full Disk
/// Access and offers a shortcut to System Settings plus a re-check button.
struct MailPermissionView: View {
    let onRefresh: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Full Disk Access Required", systemImage: "lock.shield")
        } description: {
            Text("\(AppBranding.appName) reads Apple Mail metadata from the Envelope Index database and message bodies from .emlx files. Grant Full Disk Access in System Settings, or connect a Gmail account to use the Gmail API instead.")
        } actions: {
            Button("Open Privacy Settings") {
                MailPermissionSupport.openFullDiskAccessSettings()
            }
            .accessibilityIdentifier("open-fda-settings-button")

            Button("Check Again", action: onRefresh)
                .accessibilityIdentifier("mail-permission-recheck-button")
        }
        .accessibilityIdentifier("mail-permission-view")
    }
}
#endif
