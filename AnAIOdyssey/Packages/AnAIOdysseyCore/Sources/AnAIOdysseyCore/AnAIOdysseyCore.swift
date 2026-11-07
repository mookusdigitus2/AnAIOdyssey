// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
@_exported import AIConnect

/// Namespace for the AnAIOdysseyCore package.
///
/// The package itself exposes the app's domain models, persistence layer,
/// repositories, and services; this enum exists purely as a lightweight
/// identity/metadata anchor (it is uninstantiable by design).
public enum AnAIOdysseyCore {
    /// Semantic version of the AnAIOdysseyCore package, surfaced for diagnostics
    /// and "about" screens.
    public static let version = "1.0.0"
}
