// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// Encodes/decodes HTTP chat traffic and assistant text for one remote protocol.
public protocol RemoteLLMProtocolAdapter: Sendable {
    var encoding: RemoteProtocolEncoding { get }

    func isConfigured(connection: RemoteConnection) -> Bool
    func configurationHint(connection: RemoteConnection) -> String
    func buildChatURL(baseURL: String) -> URL?
    func buildModelsURL(baseURL: String) -> URL?
    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String]
    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any]
    func parseCompletionResponse(data: Data) throws -> String
    func parseStreamingChunk(json: String) -> String?
    func parseModelsResponse(data: Data) throws -> [String]

    /// User-visible assistant prose after stripping protocol framing.
    func sanitizeAssistantText(_ text: String) -> String
    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock]
    func stripToolBlocks(from text: String, tags: Set<String>) -> String

    /// Converts a provider chunk into the incremental delta to append (handles cumulative streams).
    func streamingDelta(accumulated: String, chunk: String) -> String

    var supportsStructuredTools: Bool { get }
    func chatPayload(model: String, messages: [[String: String]], stream: Bool, tools: [[String: Any]]) -> [String: Any]
    func buildChatURL(baseURL: String, model: String, hasTools: Bool) -> URL?
    func requestBody(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        tools: [[String: Any]],
        baseURL: String,
        previousResponseID: String?,
        functionCallOutputs: [EncodedFunctionCallOutput]
    ) -> [String: Any]
}

extension RemoteLLMProtocolAdapter {
    var supportsStructuredTools: Bool { encoding.supportsStructuredTools }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool, tools: [[String: Any]]) -> [String: Any] {
        if tools.isEmpty {
            return chatPayload(model: model, messages: messages, stream: stream)
        }
        return OpenAICompatibleAPI.chatPayload(model: model, messages: messages, stream: stream, tools: tools)
    }

    func buildChatURL(baseURL: String, model: String, hasTools: Bool) -> URL? {
        buildChatURL(baseURL: baseURL)
    }

    func requestBody(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        tools: [[String: Any]],
        baseURL: String,
        previousResponseID: String? = nil,
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) -> [String: Any] {
        _ = previousResponseID
        _ = functionCallOutputs
        return chatPayload(model: model, messages: messages, stream: stream, tools: tools)
    }
}

public enum RemoteProtocolAdapterRegistry {
    public static func adapter(for encoding: RemoteProtocolEncoding) -> RemoteLLMProtocolAdapter {
        switch encoding {
        case .automatic:
            // Callers should resolve Automatic per model. An unresolved
            // Automatic is standard OpenAI tools (the non-GPT-OSS path).
            return OpenAIChatCompletionsAdapter()
        case .openAIChatCompletions:
            return OpenAIChatCompletionsAdapter()
        case .lmStudioHarmony:
            return LMStudioHarmonyAdapter()
        case .geminiOpenAI:
            return GeminiOpenAIAdapter()
        case .ollamaNative:
            return OllamaChatAdapter()
        case .anthropicMessages:
            return AnthropicMessagesAdapter()
        }
    }
}

/// Shared helpers for adapters that use OpenAI-style JSON bodies.
enum RemoteAdapterSupport {
    static func requiresAPIKey(baseURL: String) -> Bool {
        OpenAICompatibleAPI.requiresAPIKey(baseURL: baseURL)
    }

    static func isConfigured(connection: RemoteConnection) -> Bool {
        let trimmedURL = connection.trimmedBaseURL
        guard !trimmedURL.isEmpty else { return false }
        if connection.usesChatGPTAccount {
            return connection.chatgptPlanEligible == true
        }
        if requiresAPIKey(baseURL: trimmedURL) {
            return !connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    static func configurationHint(connection: RemoteConnection, urlMissing: Bool) -> String {
        if connection.trimmedBaseURL.isEmpty {
            return "Enter an API base URL."
        }
        if urlMissing {
            return "The API base URL is invalid for the selected encoding."
        }
        if connection.usesChatGPTAccount {
            if connection.chatgptPlanEligible != true {
                return ChatGPTOAuthCodec.ineligibleUserMessage
            }
            return "Sign in with ChatGPT again if requests fail."
        }
        if requiresAPIKey(baseURL: connection.trimmedBaseURL),
           connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an API key."
        }
        return "Connection is not configured."
    }

    static func defaultStreamingDelta(accumulated: String, chunk: String) -> String {
        var accumulator = StreamTextAccumulator(text: accumulated)
        return accumulator.apply(.delta(chunk))
    }
}
