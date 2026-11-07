// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore

/// Disambiguates the app's `Document` model from `SwiftUI.Document`, which was
/// introduced in the iOS/macOS 26+ SDKs and otherwise collides with
/// `AnAIOdysseyCore.Document` in any file that imports both SwiftUI and AnAIOdysseyCore.
///
/// A module-level typealias declared in this target shadows the imported
/// `SwiftUI.Document`, so unqualified `Document` references throughout `AnAIOdysseyUI`
/// resolve to our SwiftData model without needing per-file qualification.
typealias Document = DocumentModel
