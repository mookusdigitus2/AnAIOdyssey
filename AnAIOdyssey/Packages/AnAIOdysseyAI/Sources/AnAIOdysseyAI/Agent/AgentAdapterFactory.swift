// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Builds the default set of registered agent adapters for the app.
@MainActor
public enum AgentAdapterFactory {
    public static func makeDefaultRegistry(
        llmService: any LLMServiceProtocol,
        settings: AgentRegistrySettings
    ) -> AgentAdapterRegistry {
        let adapters: [any AgentAdapter] = [
            LLMAgentAdapter(
                id: "local-llm",
                displayName: "Local MLX",
                vendor: AppBranding.companyName,
                tags: ["local", "chat"],
                llmService: llmService
            ),
            LLMAgentAdapter(
                id: AgentRegistrySettings.defaultRemoteAgentID,
                displayName: "Remote OpenAI",
                vendor: "OpenAI",
                tags: ["openai", "chat"],
                llmService: llmService
            ),
            LLMAgentAdapter(
                id: "claude-design",
                displayName: "Claude (UI Design)",
                vendor: "Anthropic",
                tags: ["claude", "ui_design"],
                llmService: llmService,
                isSwitchable: true
            ),
            LLMAgentAdapter(
                id: "codex-backend",
                displayName: "Codex (Backend)",
                vendor: "OpenAI",
                tags: ["codex", "backend", "coding"],
                llmService: llmService,
                isSwitchable: true
            ),
            CursorAgentAdapter { settings.cursorCLIPath },
        ]
        return AgentAdapterRegistry(adapters: adapters)
    }
}
