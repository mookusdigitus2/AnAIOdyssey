// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// User-controlled visibility for optional top-level workspaces.
///
/// Keys use the `anaiodyssey.` prefix so `CloudDefaultsSync` mirrors them across devices.
public enum FeatureSettings {
    /// When true, the Gallery (Photos) tab appears in the top tab bar.
    public static let galleryEnabledKey = "anaiodyssey.features.galleryEnabled"
    /// Posted after `enableGallery()` so `@AppStorage` views pick up the change.
    public static let galleryEnabledDidChange = Notification.Name("anaiodyssey.features.galleryEnabledDidChange")
    /// Posted after gallery bytes/metadata change so an already-open Photos tab reloads.
    public static let galleryContentDidChange = Notification.Name("anaiodyssey.galleryContentDidChange")

    public static var isGalleryEnabled: Bool {
        UserDefaults.standard.bool(forKey: galleryEnabledKey)
    }

    /// Turns the Gallery (Photos) workspace on so generated images are visible.
    public static func enableGallery() {
        UserDefaults.standard.set(true, forKey: galleryEnabledKey)
        NotificationCenter.default.post(name: galleryEnabledDidChange, object: nil)
    }

    /// Notifies the Photos workspace that albums or images changed.
    public static func noteGalleryContentChanged() {
        NotificationCenter.default.post(name: galleryContentDidChange, object: nil)
    }
}
