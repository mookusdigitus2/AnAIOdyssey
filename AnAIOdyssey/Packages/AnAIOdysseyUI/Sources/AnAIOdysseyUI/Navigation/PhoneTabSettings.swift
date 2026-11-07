// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// iPhone tab-bar customization (Library long-press promotion).
public enum PhoneTabSettings {
    public static let promotedSectionKey = "anaiodyssey.phone.promotedLibrarySection"

    /// A Library tile promoted to the tab bar (replaces the Library tab slot).
    /// Stored raw values are unchanged from the old `LibrarySection` enum, so
    /// existing preferences carry over.
    public static var promotedLibrarySection: AppSection? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: promotedSectionKey) else { return nil }
            return AppSection(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: promotedSectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: promotedSectionKey)
            }
        }
    }
}
