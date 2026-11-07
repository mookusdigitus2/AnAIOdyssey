// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Where the active `ModelContainer` actually persists data, so the app can
/// reflect online/offline iCloud status in the UI.
public enum StorageMode: String, Sendable {
    /// On-device store only (no CloudKit mirroring).
    case local
    /// CloudKit-mirrored store synced across the user's devices.
    case cloudKit
}

/// Builds the app's SwiftData `ModelContainer`, choosing CloudKit when it can be
/// used safely and otherwise falling back to a local store.
///
/// Centralizing container creation here keeps the CloudKit availability gating
/// (which must happen *before* construction to avoid uncatchable crashes) in one
/// place.
public enum ModelContainerFactory {
    /// The CloudKit container identifier the private database mirrors into.
    /// Matches the platform entitlements (`AnAIOdyssey.entitlements` vs
    /// `AnAIOdyssey.macOS.entitlements`), which are both derived from the
    /// `BUNDLE_ID_PREFIX` build setting in `Config/Signing.xcconfig`.
    public static let cloudKitContainerID: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? AppBranding.bundleIdentifier
        #if os(macOS)
        return "iCloud.\(bundleID)"
        #else
        return "iCloud.\(bundleID).app"
        #endif
    }()

    /// Whether CloudKit mirroring can be safely enabled in the current process.
    ///
    /// `NSPersistentCloudKitContainer` (under SwiftData) does its real setup
    /// asynchronously on `com.apple.coredata.cloudkit.queue` and *aborts the
    /// process* (rather than throwing) if the binary lacks a valid iCloud
    /// entitlement or no iCloud account is signed in. That async crash can't be
    /// caught by the `do/catch` around `ModelContainer(...)`, so we gate on
    /// availability up front.
    public static var isCloudKitAvailable: Bool {
        ICloudAvailability.isAvailable
    }

    /// Creates a persistent container, preferring CloudKit when available, and
    /// reports which `StorageMode` was actually used.
    ///
    /// Pass `useCloudKit: false` to force a local store. Even when CloudKit is
    /// requested and deemed available, construction can still fail at runtime, so
    /// this gracefully degrades to the local store rather than propagating that
    /// error.
    public static func make(useCloudKit: Bool = true) throws -> (ModelContainer, StorageMode) {
        // Debug/CI escape hatch: force local storage even when iCloud is available.
        let forceLocal = ProcessInfo.processInfo.environment["ANAIODYSSEY_FORCE_LOCAL_STORAGE"] == "1"

        // Attempt the CloudKit-mirrored store only when it's both wanted and safe.
        if useCloudKit, !forceLocal, isCloudKitAvailable {
            do {
                let configuration = ModelConfiguration(
                    "CloudKit",
                    schema: AnAIOdysseySchema.schema,
                    cloudKitDatabase: .private(cloudKitContainerID)
                )
                let container = try ModelContainer(
                    for: AnAIOdysseySchema.schema,
                    configurations: configuration
                )
                return (container, .cloudKit)
            } catch {
                // Fall back to local persistence when iCloud is unavailable.
            }
        }

        // Local on-disk store: the default, and the fallback when CloudKit setup
        // was skipped or failed above.
        let configuration = ModelConfiguration(
            "Local",
            schema: AnAIOdysseySchema.schema,
            isStoredInMemoryOnly: false
        )
        let container = try ModelContainer(
            for: AnAIOdysseySchema.schema,
            configurations: configuration
        )
        return (container, .local)
    }

    /// In-memory container for tests.
    ///
    /// Backed by the same schema but never touches disk or CloudKit, so tests
    /// start from a clean, isolated store every time.
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: AnAIOdysseySchema.schema, configurations: configuration)
    }
}

/// CloudKit record size guard — large document bodies stay local-only in future if needed.
///
/// CloudKit rejects oversized string fields, so this provides a conservative
/// byte budget callers can check before relying on a value syncing.
public enum CloudKitCompatibility {
    /// Conservative per-string byte ceiling that stays under CloudKit's limits.
    public static let maxRecommendedStringBytes = 900_000

    /// Whether `text` is small enough (by UTF-8 byte count) to safely sync via
    /// CloudKit.
    public static func isCloudKitCompatible(text: String) -> Bool {
        text.utf8.count <= maxRecommendedStringBytes
    }
}
