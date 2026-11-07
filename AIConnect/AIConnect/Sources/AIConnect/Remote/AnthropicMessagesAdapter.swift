// SPDX-License-Identifier: MIT
import Foundation

/// Anthropic Messages API (`/v1/messages`) adapter.
struct AnthropicMessagesAdapter: RemoteLLMProtocolAdapter {
    let encoding: RemoteProtocolEncoding = .anthropicMessages
    private let apiProvider: RemoteAPIProvider = .anthropic

    func isConfigured(connection: RemoteConnection) -> Bool {
        RemoteAdapterSupport.isConfigured(connection: connection)
            && buildChatURL(baseURL: connection.trimmedBaseURL) != nil
    }

    func configurationHint(connection: RemoteConnection) -> String {
        RemoteAdapterSupport.configurationHint(
            connection: connection,
            urlMissing: buildChatURL(baseURL: connection.trimmedBaseURL) == nil
        )
    }

    func buildChatURL(baseURL: String) -> URL? {
        OpenAICompatibleAPI.buildChatCompletionsURL(baseURL: baseURL, provider: apiProvider)
    }

    func buildModelsURL(baseURL: String) -> URL? {
        nil
    }

    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String] {
        OpenAICompatibleAPI.requestHeaders(
            baseURL: connection.trimmedBaseURL,
            apiKey: connection.apiKey,
            streaming: streaming,
            provider: apiProvider
        )
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool, tools: [[String: Any]]) -> [String: Any] {
        OpenAICompatibleAPI.anthropicMessagesPayload(model: model, messages: messages, stream: stream)
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        OpenAICompatibleAPI.anthropicMessagesPayload(model: model, messages: messages, stream: stream)
    }

    func parseCompletionResponse(data: Data) throws -> String {
        try OpenAICompatibleAPI.parseAnthropicCompletionResponse(data)
    }

    func parseStreamingChunk(json: String) -> String? {
        OpenAICompatibleAPI.parseAnthropicStreamingChunk(json)
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        if let model = try? JSONDecoder().decode([String: String].self, from: data)["model"] {
            return [model]
        }
        return ["claude-3-5-sonnet-latest"]
    }

    func sanitizeAssistantText(_ text: String) -> String { text }

    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        ToolCallParsing.parseToolBlocks(from: text, tags: tags)
    }

    func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        ToolCallParsing.stripToolBlocks(from: text, tags: tags)
    }

    var supportsStructuredTools: Bool { false }

    func streamingDelta(accumulated: String, chunk: String) -> String {
        RemoteAdapterSupport.defaultStreamingDelta(accumulated: accumulated, chunk: chunk)
    }
}
