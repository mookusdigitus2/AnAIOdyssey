// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI

// Wires the AI services into SwiftUI's dependency-injection system so views can
// reach the active LLM and web-search backends via `@Environment` without
// threading them manually through every initializer.

/// Environment key carrying the active chat backend; `nil` until the app injects one at launch.
private struct LLMServiceKey: EnvironmentKey {
    static let defaultValue: (any LLMServiceProtocol)? = nil
}

public extension EnvironmentValues {
    /// The chat LLM service available to the current view tree.
    var llmService: (any LLMServiceProtocol)? {
        get { self[LLMServiceKey.self] }
        set { self[LLMServiceKey.self] = newValue }
    }

}
