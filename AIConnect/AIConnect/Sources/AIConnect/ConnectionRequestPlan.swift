// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// What a request to one connection and model carries, resolved from the shared settings: the
/// OpenAI API choice and the per-model Options (thinking level, max output, context, remember
/// thinking). The same rules ``RemoteLLMService`` applies, for apps with their own wire client.
public struct ConnectionRequestPlan: Equatable, Sendable {
    public var usesResponsesAPI: Bool
    /// Only a level the model accepts; nil means send nothing.
    public var reasoningEffort: ReasoningEffort?
    public var maxOutputTokens: Int?
    public var usesMaxCompletionTokens: Bool
    /// Responses only: keep encrypted reasoning across turns.
    public var rememberThinking: Bool
    public var contextWindowTokens: Int?

    public init(usesResponsesAPI: Bool, reasoningEffort: ReasoningEffort?, maxOutputTokens: Int?,
                usesMaxCompletionTokens: Bool, rememberThinking: Bool, contextWindowTokens: Int?) {
        self.usesResponsesAPI = usesResponsesAPI
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.rememberThinking = rememberThinking
        self.contextWindowTokens = contextWindowTokens
    }

    public static func resolve(
        connection: RemoteConnection,
        modelID: String,
        hasTools: Bool,
        options: ModelGenerationOptions? = nil
    ) -> ConnectionRequestPlan {
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: modelID,
            backend: .remote,
            live: connection.liveCapabilities(for: modelID)
        )
        let stored = options ?? ModelGenerationSettings.options(connectionID: connection.id, modelID: modelID)
        let responses = connection.usesResponsesAPI(model: modelID, hasTools: hasTools)
        // Only a level picked in Options (or one the model always needs). LM Studio's listed
        // levels and default are not copied into requests: with nothing sent, the server applies
        // the model's own default, and a listed `high` crashes templates such as Qwen3.8's.
        let effort = ModelCapabilityCatalog.sanitizedReasoningEffort(stored.reasoningEffort, capabilities: caps)

        var maxOutput: Int?
        if let requested = stored.maxOutputTokens, requested > 0 {
            maxOutput = responses ? min(requested, caps.maxOutputTokens) : requested
        } else if caps.alwaysSendsReasoningEffort || (responses && caps.prefersResponsesAPI) {
            maxOutput = caps.maxOutputTokens
        }
        var remember = responses && caps.supportsRememberThinking
            && ModelOptionsFormatting.resolvedRememberThinking(options: stored, capabilities: caps)
        if connection.usesChatGPTAccount {
            // The plan route rejects max_output_tokens and include.
            maxOutput = nil
            remember = false
        }
        return ConnectionRequestPlan(
            usesResponsesAPI: responses,
            reasoningEffort: effort,
            maxOutputTokens: maxOutput,
            usesMaxCompletionTokens: caps.usesMaxCompletionTokens,
            rememberThinking: remember,
            contextWindowTokens: ModelCapabilityCatalog.clampContextTokens(stored.contextWindowTokens, capabilities: caps)
        )
    }
}
