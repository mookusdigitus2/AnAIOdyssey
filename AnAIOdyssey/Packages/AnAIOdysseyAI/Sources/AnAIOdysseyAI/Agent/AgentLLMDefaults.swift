// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Maps Settings → Agents & Controller selections to concrete LLM backend/model choices.
@MainActor
public enum AgentLLMDefaults {
    public static func defaultSelectionKey(
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) -> String {
        selectionKey(
            forAgentID: agentSettings.resolvedControllerID,
            providerSettings: providerSettings
        )
    }

    public static func selectionKey(
        forAgentID agentID: String,
        providerSettings: ProviderSettings
    ) -> String {
        switch agentID {
        case "local-llm":
            return localDefaultSelectionKey(providerSettings: providerSettings)
        case AgentRegistrySettings.defaultRemoteAgentID, "claude-design", "codex-backend":
            return remoteDefaultSelectionKey(providerSettings: providerSettings)
                ?? localDefaultSelectionKey(providerSettings: providerSettings)
        default:
            return ConfiguredModelRegistry.defaultChoice(providerSettings: providerSettings).selectionKey
        }
    }

    public static func applyDefaultFromAgent(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        agentSettings: AgentRegistrySettings
    ) {
        let key = defaultSelectionKey(
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
        apply(
            selectionKey: key,
            to: llmService,
            providerSettings: providerSettings
        )
    }

    public static func apply(
        selectionKey: String,
        to llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings
    ) {
        guard let parsed = ConfiguredModelRegistry.parseSelectionKey(selectionKey) else {
            let fallback = ConfiguredModelRegistry.defaultChoice(providerSettings: providerSettings)
            setModel(
                fallback.id,
                backend: fallback.backend,
                connectionID: fallback.connectionID,
                on: llmService
            )
            return
        }
        setModel(
            parsed.modelID,
            backend: parsed.backend,
            connectionID: parsed.connectionID,
            on: llmService
        )
    }

    private static func localDefaultSelectionKey(providerSettings: ProviderSettings) -> String {
        let choices = ConfiguredModelRegistry.availableChoices(providerSettings: providerSettings)
        if OnDeviceLanguageModelSupport.appleFoundationIsReady,
           let apple = choices.first(where: { $0.backend == .appleFoundation }) {
            return apple.selectionKey
        }
        if let local = choices.first(where: { $0.backend == .localMLX }) {
            return local.selectionKey
        }
        return ConfiguredModelRegistry.defaultChoice(providerSettings: providerSettings).selectionKey
    }

    private static func remoteDefaultSelectionKey(
        providerSettings: ProviderSettings
    ) -> String? {
        guard let connection = providerSettings.resolvedConnection() else { return nil }
        let modelID = connection.trimmedModel
        guard !modelID.isEmpty else { return nil }
        return ConfiguredModelRegistry.selectionKey(
            modelID: modelID,
            backend: .remote,
            connectionID: connection.id
        )
    }

    private static func setModel(
        _ modelID: String,
        backend: LLMBackendPreference,
        connectionID: String?,
        on llmService: any LLMServiceProtocol
    ) {
        if let connectionSelectable = llmService as? any RemoteConnectionSelectable {
            connectionSelectable.backendPreference = backend
            connectionSelectable.selectedRemoteConnectionID = connectionID
            connectionSelectable.selectedModelID = modelID
        } else if let selectable = llmService as? any LLMBackendSelectable {
            selectable.backendPreference = backend
            selectable.selectedModelID = modelID
        } else {
            llmService.selectedModelID = modelID
        }

        if let remoteCapable = llmService as? RemoteLLMCapable {
            if backend == .remote {
                remoteCapable.setActiveConnection(id: connectionID, modelID: modelID)
            } else {
                remoteCapable.setActiveConnection(id: nil, modelID: nil)
            }
        }
    }
}
