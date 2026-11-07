// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
import AIConnect

/// Environment key carrying the active web-search backend used by research/agent features.
private struct WebSearchServiceKey: EnvironmentKey {
    static let defaultValue: (any WebSearchServiceProtocol)? = nil
}

public extension EnvironmentValues {
    /// The web-search service available to the current view tree.
    var webSearchService: (any WebSearchServiceProtocol)? {
        get { self[WebSearchServiceKey.self] }
        set { self[WebSearchServiceKey.self] = newValue }
    }
}
