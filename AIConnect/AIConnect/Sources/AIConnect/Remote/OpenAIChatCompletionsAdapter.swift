// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

struct OpenAIChatCompletionsAdapter: RemoteLLMProtocolAdapter {
    let encoding: RemoteProtocolEncoding = .openAIChatCompletions
    private let apiProvider: RemoteAPIProvider = .openAICompatible

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

    func buildChatURL(baseURL: String, model: String, hasTools: Bool) -> URL? {
        OpenAICompatibleAPI.buildConversationURL(
            baseURL: baseURL,
            model: model,
            hasTools: hasTools,
            provider: apiProvider
        )
    }

    func buildModelsURL(baseURL: String) -> URL? {
        OpenAICompatibleAPI.buildModelsURL(baseURL: baseURL, provider: apiProvider)
    }

    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String] {
        OpenAICompatibleAPI.requestHeaders(
            baseURL: connection.trimmedBaseURL,
            apiKey: connection.apiKey,
            streaming: streaming,
            provider: apiProvider
        )
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        OpenAICompatibleAPI.chatPayload(model: model, messages: messages, stream: stream)
    }

    func requestBody(
        model: String,
        messages: [[String: String]],
        stream: Bool,
        tools: [[String: Any]],
        baseURL: String,
        previousResponseID: String?,
        functionCallOutputs: [EncodedFunctionCallOutput]
    ) -> [String: Any] {
        if OpenAIRequestCodec.shouldUseResponsesAPI(
            baseURL: baseURL,
            model: model,
            hasTools: !tools.isEmpty,
            hasHostedWebSearch: OpenAIRequestCodec.containsHostedWebSearch(tools)
        ) {
            return OpenAIRequestCodec.responsesPayload(
                model: model,
                messages: messages,
                stream: stream,
                tools: tools,
                previousResponseID: previousResponseID,
                functionCallOutputs: functionCallOutputs
            )
        }
        return chatPayload(model: model, messages: messages, stream: stream, tools: tools)
    }

    func parseCompletionResponse(data: Data) throws -> String {
        if let error = OpenAIRequestCodec.responsesCompletionError(in: data) {
            throw LLMServiceError.generationFailed(error)
        }
        if let text = OpenAIRequestCodec.parseResponsesCompletion(data), !text.isEmpty {
            return text
        }
        return try OpenAICompatibleAPI.parseCompletionResponse(data)
    }

    func parseStreamingChunk(json: String) -> String? {
        if let delta = OpenAIRequestCodec.parseResponsesStreamingDelta(json) {
            return delta
        }
        return OpenAICompatibleAPI.parseStreamingChunk(json)
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        try OpenAICompatibleAPI.parseModelsResponse(data)
    }

    func sanitizeAssistantText(_ text: String) -> String {
        LMStudioToolProtocol.prose(from: text)
    }

    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        var blocks = ToolCallParsing.parseToolBlocks(from: text, tags: tags)
        if HarmonyResponseCodec.containsHarmonyTokens(text) {
            blocks.append(contentsOf: HarmonyResponseCodec.parseHarmonyToolCalls(from: text, tags: tags))
        }
        for call in LMStudioToolProtocol.calls(inContent: text) {
            guard let tag = tags.first(where: { $0.lowercased() == call.name.lowercased() }) else { continue }
            blocks.append(ToolCallBlock(toolType: tag.lowercased(), content: call.argumentsJSON, callID: call.id))
        }
        return blocks
    }

    func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        LMStudioToolProtocol.prose(from: ToolCallParsing.stripToolBlocks(from: text, tags: tags))
    }

    func streamingDelta(accumulated: String, chunk: String) -> String {
        RemoteAdapterSupport.defaultStreamingDelta(accumulated: accumulated, chunk: chunk)
    }
}

struct GeminiOpenAIAdapter: RemoteLLMProtocolAdapter {
    let encoding: RemoteProtocolEncoding = .geminiOpenAI
    private let apiProvider: RemoteAPIProvider = .gemini

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
        OpenAICompatibleAPI.buildModelsURL(baseURL: baseURL, provider: apiProvider)
    }

    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String] {
        OpenAICompatibleAPI.requestHeaders(
            baseURL: connection.trimmedBaseURL,
            apiKey: connection.apiKey,
            streaming: streaming,
            provider: apiProvider
        )
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        OpenAICompatibleAPI.chatPayload(model: model, messages: messages, stream: stream)
    }

    func parseCompletionResponse(data: Data) throws -> String {
        try OpenAICompatibleAPI.parseCompletionResponse(data)
    }

    func parseStreamingChunk(json: String) -> String? {
        OpenAICompatibleAPI.parseStreamingChunk(json)
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        try OpenAICompatibleAPI.parseModelsResponse(data)
    }

    func sanitizeAssistantText(_ text: String) -> String {
        text
    }

    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        ToolCallParsing.parseToolBlocks(from: text, tags: tags)
    }

    func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        ToolCallParsing.stripToolBlocks(from: text, tags: tags)
    }

    func streamingDelta(accumulated: String, chunk: String) -> String {
        RemoteAdapterSupport.defaultStreamingDelta(accumulated: accumulated, chunk: chunk)
    }
}

struct OllamaChatAdapter: RemoteLLMProtocolAdapter {
    let encoding: RemoteProtocolEncoding = .ollamaNative
    private let apiProvider: RemoteAPIProvider = .ollama

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
        OpenAICompatibleAPI.buildModelsURL(baseURL: baseURL, provider: apiProvider)
    }

    func requestHeaders(connection: RemoteConnection, streaming: Bool) -> [String: String] {
        OpenAICompatibleAPI.requestHeaders(
            baseURL: connection.trimmedBaseURL,
            apiKey: connection.apiKey,
            streaming: streaming,
            provider: apiProvider
        )
    }

    func chatPayload(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        OpenAICompatibleAPI.chatPayload(model: model, messages: messages, stream: stream)
    }

    func parseCompletionResponse(data: Data) throws -> String {
        try OpenAICompatibleAPI.parseCompletionResponse(data)
    }

    func parseStreamingChunk(json: String) -> String? {
        OpenAICompatibleAPI.parseStreamingChunk(json)
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        try OpenAICompatibleAPI.parseModelsResponse(data)
    }

    func sanitizeAssistantText(_ text: String) -> String {
        text
    }

    func parseToolBlocks(from text: String, tags: Set<String>) -> [ToolCallBlock] {
        ToolCallParsing.parseToolBlocks(from: text, tags: tags)
    }

    func stripToolBlocks(from text: String, tags: Set<String>) -> String {
        ToolCallParsing.stripToolBlocks(from: text, tags: tags)
    }

    func streamingDelta(accumulated: String, chunk: String) -> String {
        RemoteAdapterSupport.defaultStreamingDelta(accumulated: accumulated, chunk: chunk)
    }
}
