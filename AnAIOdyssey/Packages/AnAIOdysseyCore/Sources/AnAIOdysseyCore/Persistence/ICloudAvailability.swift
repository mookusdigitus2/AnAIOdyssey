// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import CloudKit
import Foundation
import Security

/// Determines whether iCloud features (CloudKit mirroring and the key-value
/// store) can be safely used in the current process.
///
/// Enabling these without a valid iCloud entitlement — e.g. unsigned/teamless
/// builds, or the Simulator with no iCloud account — causes hard crashes deep
/// inside CloudKit/CoreData or the ubiquitous-KVS XPC machinery (for example
/// `-[OS_dispatch_mach_msg _setContext:]: unrecognized selector`). Those crashes
/// happen asynchronously and can't be caught, so we must gate up front.
public enum ICloudAvailability {
    /// True only when the user is signed into iCloud AND the binary actually
    /// carries a non-empty iCloud-container entitlement.
    public static var isAvailable: Bool {
        // Require a signed-in iCloud account first (cheap check), then confirm the
        // binary is actually entitled to use an iCloud container.
        guard isAccountSignedIn else { return false }
        return hasICloudContainerEntitlement
    }

    /// Whether an iCloud account is signed in on this device (ignores entitlements).
    ///
    /// `ubiquityIdentityToken` is `nil` when iCloud Drive is disabled, even though
    /// CloudKit itself only needs an iCloud account. To avoid silently falling back
    /// to local storage on such devices, we also honor the cached result of the
    /// async `CKContainer.accountStatus()` probe from a previous launch (see
    /// `refreshAccountStatus()`).
    public static var isAccountSignedIn: Bool {
        if FileManager.default.ubiquityIdentityToken != nil { return true }
        return UserDefaults.standard.bool(forKey: accountStatusCacheKey)
    }

    /// UserDefaults key caching the last observed CloudKit account availability.
    private static let accountStatusCacheKey = "anaiodyssey.icloud.ckAccountAvailable"

    /// Asynchronously probes CloudKit for the real account status and caches it.
    ///
    /// The synchronous gating at launch can't wait for this, so the result takes
    /// effect on the *next* launch — good enough to recover devices where iCloud
    /// Drive is off but an iCloud account is signed in. Only runs when the binary
    /// is entitled, because constructing `CKContainer` without the entitlement
    /// raises an exception.
    public static func refreshAccountStatus() async {
        guard hasICloudContainerEntitlement else { return }
        let status = try? await CKContainer(
            identifier: ModelContainerFactory.cloudKitContainerID
        ).accountStatus()
        UserDefaults.standard.set(status == .available, forKey: accountStatusCacheKey)
    }

    /// Whether this binary carries a non-empty iCloud-container entitlement.
    public static var hasICloudContainerEntitlement: Bool {
        #if os(macOS)
        return macOSHasICloudContainerEntitlement
        #else
        return iOSHasICloudContainerEntitlement
        #endif
    }

    #if os(macOS)
    /// macOS can read live process entitlements via `SecTask`.
    private static var macOSHasICloudContainerEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let identifiers = value as? [String] {
            return !identifiers.isEmpty
        }
        return false
    }
    #else
    /// iOS has no public entitlement-introspection API. Inspect the embedded
    /// development provisioning profile when present (device/debug builds); App
    /// Store / TestFlight builds omit it, so assume entitlements match the App
    /// Store Connect configuration in release.
    private static var iOSHasICloudContainerEntitlement: Bool {
        // When signed in, ask the system whether this build can reach the container.
        // Parsing `embedded.mobileprovision` alone is brittle (binary profiles, stale caches).
        if isAccountSignedIn,
           FileManager.default.url(forUbiquityContainerIdentifier: ModelContainerFactory.cloudKitContainerID) != nil {
            return true
        }
        #if DEBUG
        return provisioningProfileGrantsICloudContainer
        #else
        return true
        #endif
    }

    /// Parses `embedded.mobileprovision` for the iCloud container entitlement.
    ///
    /// Xcode strips entitlements that aren't enabled on the App ID, so an empty
    /// or missing container entry means we must not enable CloudKit.
    private static var provisioningProfileGrantsICloudContainer: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let ascii = String(data: data, encoding: .ascii)
        else {
            // Simulator / unsigned builds have no profile — stay local.
            return false
        }
        return ascii.contains("com.apple.developer.icloud-container-identifiers")
            && ascii.contains(ModelContainerFactory.cloudKitContainerID)
    }
    #endif
}
