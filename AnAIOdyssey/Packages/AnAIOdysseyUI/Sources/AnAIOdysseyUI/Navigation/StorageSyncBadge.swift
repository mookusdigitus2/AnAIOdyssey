// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// Warns when data is local-only while iCloud sync could be active.
struct StorageSyncBadge: View {
    let storageMode: StorageMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if storageMode == .local, shouldWarnAboutLocalStorage {
            Group {
                if horizontalSizeClass == .compact {
                    Image(systemName: "icloud.slash")
                } else {
                    Label("Local only", systemImage: "icloud.slash")
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, horizontalSizeClass == .compact ? 6 : 8)
            .padding(.vertical, 4)
            .foregroundStyle(AegeanColors.warning(colorScheme))
            .background(
                Capsule()
                    .fill(AegeanColors.warning(colorScheme).opacity(0.12))
            )
            .accessibilityLabel(storageAccessibilityLabel)
        }
    }

    /// Only warn when iCloud is signed in and this build can use CloudKit, but the
    /// active store is still local (unexpected fallback).
    private var shouldWarnAboutLocalStorage: Bool {
        ICloudAvailability.isAccountSignedIn && ICloudAvailability.hasICloudContainerEntitlement
    }

    private var storageAccessibilityLabel: String {
        "Data is stored locally and not syncing to iCloud"
    }
}
