// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIConnect

@MainActor
public extension LLMModelPreparer {
    /// Computes the research run configuration the user's settings imply.
    ///
    /// Honors "use the chat model" (downgrading a pinned local choice to `.auto`
    /// for resilience), and avoids selecting remote when no provider is configured.
    static func preferredResearchConfiguration(
        providerSettings: ProviderSettings,
        chatModelID: String,
        chatBackend: LLMBackendPreference,
        useChatModel: Bool,
        dedicatedModelID: String,
        dedicatedBackend: LLMBackendPreference
    ) -> ResearchRunConfiguration {
        // Reuse the chat model: a pinned local choice becomes .auto so research can still fall back.
        if useChatModel {
            return ResearchRunConfiguration(
                modelID: chatModelID,
                backend: chatBackend == .localMLX ? .auto : chatBackend
            )
        }

        // Dedicated model wants remote but none is configured — soften to .auto.
        if dedicatedBackend == .remote, !providerSettings.isRemoteConfigured {
            return ResearchRunConfiguration(
                modelID: dedicatedModelID,
                backend: .auto
            )
        }

        return ResearchRunConfiguration(
            modelID: dedicatedModelID,
            backend: dedicatedBackend
        )
    }

    /// Sensible research defaults: the configured remote model if available, else the local default via `.auto`.
    static func defaultResearchConfiguration(
        providerSettings: ProviderSettings
    ) -> ResearchRunConfiguration {
        if let connection = providerSettings.resolvedConnection(),
           !connection.trimmedModel.isEmpty {
            return ResearchRunConfiguration(
                modelID: connection.trimmedModel,
                backend: .remote,
                connectionID: connection.id
            )
        }
        return ResearchRunConfiguration(
            modelID: LLMModelCatalog.defaultModelID,
            backend: .auto
        )
    }

}
