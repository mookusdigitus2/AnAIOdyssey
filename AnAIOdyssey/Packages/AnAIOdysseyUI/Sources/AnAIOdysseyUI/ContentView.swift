// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// Public entry point view for the UI package.
///
/// This is a thin wrapper that hosts ``RootView`` and forwards the storage mode.
/// It exists so previews, tests, and host apps can embed the workspace without
/// reaching into the navigation internals.
public struct ContentView: View {
    /// Where persisted data lives (local on-device vs. iCloud/CloudKit), surfaced
    /// to the Settings screen so the user can see the active sync mode.
    let storageMode: StorageMode

    public init(storageMode: StorageMode = .local) {
        self.storageMode = storageMode
    }

    /// Hands off to ``RootView``, which owns the sidebar/detail split layout.
    public var body: some View {
        RootView(storageMode: storageMode)
    }
}

#Preview {
    ContentView()
}
