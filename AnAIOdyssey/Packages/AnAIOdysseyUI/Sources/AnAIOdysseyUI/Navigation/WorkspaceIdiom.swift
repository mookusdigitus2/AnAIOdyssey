// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device idiom, not size class. Plus/Max landscape is regular width and
/// must still use the phone chrome.
enum WorkspaceIdiom {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}
