// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
import AnAIOdysseyAI


/// Helpers that translate the picker's encoded `selectionKey` to and from concrete
/// model/backend configuration, shared by chat, research, and compare.
///
/// The key encodes both a model id and a backend preference; these functions are
/// the single place that mapping logic lives so every surface resolves models the
/// same way (and consistently treats local MLX as `.auto`).
@MainActor
enum WorkspaceModelSelection {
    /// Decodes a selection key into a research run configuration, falling back to
    /// the provider's default choice when the key can't be parsed.
    static func configuration(
        from selectionKey: String,
        providerSettings: ProviderSettings
    ) -> ResearchRunConfiguration {
        if let parsed = ConfiguredModelRegistry.parseSelectionKey(selectionKey) {
            // Treat explicit local-MLX as `.auto` so the service can choose freely.
            let backend: LLMBackendPreference = parsed.backend == .localMLX ? .auto : parsed.backend
            return ResearchRunConfiguration(
                modelID: parsed.modelID,
                backend: backend,
                connectionID: parsed.connectionID
            )
        }
        let fallback = ConfiguredModelRegistry.defaultChoice(providerSettings: providerSettings)
        return ResearchRunConfiguration(
            modelID: fallback.id,
            backend: fallback.backend == .localMLX ? .auto : fallback.backend
        )
    }

    /// Applies a selection key to a live LLM service, setting both the backend
    /// preference and model id when the service supports backend selection.
    static func apply(
        selectionKey: String,
        to llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings
    ) {
        AgentLLMDefaults.apply(
            selectionKey: selectionKey,
            to: llmService,
            providerSettings: providerSettings
        )
    }

    /// The provider's default selection key, used to seed empty pickers.
    static func defaultSelectionKey(providerSettings: ProviderSettings) -> String {
        ConfiguredModelRegistry.defaultChoice(providerSettings: providerSettings).selectionKey
    }

    /// Default model for the active controller agent from Settings → Agents & Controller.
    static func defaultSelectionKey(
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) -> String {
        AgentLLMDefaults.defaultSelectionKey(
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
    }

    /// Default model for a feature tab, falling back to global then controller agent.
    static func defaultSelectionKey(
        for feature: WorkspaceFeature,
        featureModelSettings: FeatureModelSettings,
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) -> String {
        featureModelSettings.resolvedSelectionKey(
            for: feature,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
    }

    /// Reloads a tab's picker (and optional shared LLM service) from Settings defaults.
    static func applyFeatureDefault(
        for feature: WorkspaceFeature,
        selectionKey: inout String,
        featureModelSettings: FeatureModelSettings,
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings,
        llmService: (any LLMServiceProtocol)? = nil
    ) {
        let key = defaultSelectionKey(
            for: feature,
            featureModelSettings: featureModelSettings,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
        selectionKey = key
        if let llmService {
            apply(selectionKey: key, to: llmService, providerSettings: providerSettings)
        }
    }

    /// Persists a feature tab's default model when the user changes the toolbar picker.
    static func persistDefault(
        _ selectionKey: String,
        for feature: WorkspaceFeature,
        featureModelSettings: FeatureModelSettings
    ) {
        featureModelSettings.setSelectionKey(selectionKey, for: feature)
    }

    /// Maps a registered agent adapter id to the workspace model selection key it represents.
    static func selectionKey(
        forAgentID agentID: String,
        providerSettings: ProviderSettings
    ) -> String {
        AgentLLMDefaults.selectionKey(forAgentID: agentID, providerSettings: providerSettings)
    }

    /// Applies the Settings controller agent as the shared LLM default.
    static func applyDefaultFromAgent(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) {
        AgentLLMDefaults.applyDefaultFromAgent(
            llmService: llmService,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
    }

    /// Derives the selection key that matches a service's current model/backend,
    /// so a picker can reflect the live state on first appearance.
    static func selectionKey(
        matching llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings
    ) -> String {
        let modelID = llmService.selectedModelID
        let backend = (llmService as? any LLMBackendSelectable)?.backendPreference
            ?? ConfiguredModelRegistry.inferredBackend(for: modelID, providerSettings: providerSettings)
        let connectionID = (llmService as? any RemoteConnectionSelectable)?.selectedRemoteConnectionID
        let key = ConfiguredModelRegistry.selectionKey(
            modelID: modelID,
            backend: backend,
            connectionID: connectionID
        )
        if ConfiguredModelRegistry.choice(forSelectionKey: key, providerSettings: providerSettings) != nil {
            return key
        }
        return defaultSelectionKey(providerSettings: providerSettings)
    }
}
