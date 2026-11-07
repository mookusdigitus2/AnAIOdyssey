// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import SwiftUI

/// Generation limits for MLX and agent runs, persisted per feature.
@MainActor
public final class AgentGenerationSettings: ObservableObject {
    private enum Keys {
        static let maxTokens = "anaiodyssey.agent.maxTokens"
        static let temperature = "anaiodyssey.agent.temperature"
    }

    @Published public var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }

    @Published public var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTokens = defaults.integer(forKey: Keys.maxTokens)
        self.maxTokens = storedTokens > 0 ? storedTokens : 2048
        let storedTemp = defaults.double(forKey: Keys.temperature)
        self.temperature = storedTemp > 0 ? storedTemp : 0.7
    }
}
