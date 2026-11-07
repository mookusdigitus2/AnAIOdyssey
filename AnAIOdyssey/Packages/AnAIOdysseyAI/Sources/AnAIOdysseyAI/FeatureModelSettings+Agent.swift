// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIConnect

/// Odyssey falls back to its controller agent's model when no default is set.
public extension FeatureModelSettings {
    /// Effective global default: stored global override, otherwise controller agent.
    func resolvedGlobalSelectionKey(
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) -> String {
        if let stored = globalSelectionKey(),
           isValidSelectionKey(stored, providerSettings: providerSettings) {
            return stored
        }
        return AgentLLMDefaults.defaultSelectionKey(
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
    }

    /// Effective default for a feature tab using override → global → controller agent.
    func resolvedSelectionKey(
        for feature: WorkspaceFeature,
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) -> String {
        if let stored = selectionKey(for: feature),
           isValidSelectionKey(stored, providerSettings: providerSettings) {
            return stored
        }
        if let global = globalSelectionKey(),
           isValidSelectionKey(global, providerSettings: providerSettings) {
            return global
        }
        return AgentLLMDefaults.defaultSelectionKey(
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
    }

}
