// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Registry of all `AgentAdapter` instances; resolves controller and tagged agents.
@MainActor
public final class AgentAdapterRegistry: ObservableObject {
    private var adapters: [String: any AgentAdapter] = [:]

    public init(adapters: [any AgentAdapter] = []) {
        for adapter in adapters {
            register(adapter)
        }
    }

    public func register(_ adapter: any AgentAdapter) {
        adapters[adapter.attributes.id] = adapter
    }

    public func adapter(id: String) -> (any AgentAdapter)? {
        adapters[id]
    }

    public var allAdapters: [any AgentAdapter] {
        adapters.values.sorted { $0.attributes.displayName < $1.attributes.displayName }
    }

    public var availableAdapters: [any AgentAdapter] {
        allAdapters.filter(\.isAvailable)
    }

    public func adapters(matchingTag tag: String) -> [any AgentAdapter] {
        availableAdapters.filter { $0.attributes.tags.contains(tag) }
    }

    public func firstAvailable(matchingTag tag: String) -> (any AgentAdapter)? {
        adapters(matchingTag: tag).first
    }
}
