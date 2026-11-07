// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
@_exported import AIModelOptions
@_exported import AIConnect
@_exported import AIConnectVoice

/// Top-level namespace and entry point for the AI layer of AnAIOdyssey.
///
/// `AnAIOdysseyAI` exposes package-wide metadata (the shared version string) and
/// the conventions for where on-device model weights are cached, so the rest of
/// the app does not need to hard-code paths or version handling.
public enum AnAIOdysseyAI {
    /// Package version, kept in lockstep with `AnAIOdysseyCore` so all layers report a single coherent version.
    public static let version = AnAIOdysseyCore.version

    /// Filesystem location where downloaded MLX model weights are stored.
    ///
    /// Lives under Application Support so the OS treats it as user data that
    /// should persist (and be backed up) rather than disposable caches.
    public static var modelCacheDirectory: URL {
        AppBranding.applicationSupportDirectory().appendingPathComponent("models", isDirectory: true)
    }

    /// Creates the model cache directory if it does not already exist.
    ///
    /// Called before model downloads so the destination is guaranteed to exist.
    /// Runs on the main actor and intentionally ignores errors: a failure here
    /// surfaces later as a more actionable load error from the model factory.
    @MainActor
    public static func ensureModelCacheDirectoryExists() {
        try? FileManager.default.createDirectory(at: modelCacheDirectory, withIntermediateDirectories: true)
    }
}
