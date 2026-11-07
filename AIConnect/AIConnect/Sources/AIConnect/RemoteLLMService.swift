// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// Identifies which remote connection is active and exposes its protocol adapter.
@MainActor
public protocol RemoteLLMCapable: LLMServiceProtocol {
    var activeConnectionID: String? { get }
    var activeProtocolAdapter: RemoteLLMProtocolAdapter? { get }
    func setActiveConnection(id: String?, modelID: String?)
}

/// Exposes the embedded remote service used by composite backends for structured agent rounds.
@MainActor
public protocol AgentRemoteLLMProviding: AnyObject {
    var remoteServiceForAgent: RemoteLLMService { get }
}

/// `LLMServiceProtocol` backed by a configured `RemoteConnection` and its encoding adapter.
@MainActor
public final class RemoteLLMService: LLMServiceProtocol, RemoteLLMCapable {
    public var activeConnectionID: String?
    public private(set) var isModelLoaded = false
    public private(set) var loadProgress: Double?
    public var loadStatus = "Remote not configured"
    public let usesMLXBackend = false

    /// Local models often sit in prompt processing for well over a minute before
    /// the first token. `URLSession.shared` drops the socket after 60s of silence,
    /// which LM Studio logs as "Client disconnected" and an empty completion.
    /// Idle timeout is configurable; the resource cap is a long ceiling, not 10 minutes.
    private static var chatTimeout: TimeInterval { RemoteChatTimeout.idleSeconds() }

    private let settings: ProviderSettings
    private let session: URLSession
    private let chatGPTAccounts: ChatGPTAccountService
    private var queriedModels: [LLMModelOption] = []
    private var activeModelOverride: String?
    /// Function calls from the last agent round. The ChatGPT plan route is
    /// stateless (`store:false`), so they are resent ahead of their outputs.
    private var lastFunctionCalls: [EncodedFunctionCall] = []
    /// Token usage from the last completed chat or agent request, if the provider sent it.
    public private(set) var lastTokenUsage: TokenUsage?

    public var activeProtocolAdapter: RemoteLLMProtocolAdapter? {
        guard let connection = activeConnection else { return nil }
        return settings.adapter(for: connection, modelID: selectedModelID)
    }

    public var selectedModelID: String {
        get {
            if let override = activeModelOverride, !override.isEmpty { return override }
            return activeConnection?.trimmedModel ?? ""
        }
        set {
            activeModelOverride = newValue
            if let id = activeConnectionID,
               let index = settings.remoteConnections.firstIndex(where: { $0.id == id }) {
                settings.remoteConnections[index].defaultModel = newValue
            }
        }
    }

    /// The selected connection. A ChatGPT account whose plan usage was turned
    /// off resolves to the matching API-key connection when there is one.
    private var activeConnection: RemoteConnection? {
        guard let id = activeConnectionID, let connection = settings.connection(id: id) else { return nil }
        if connection.usesChatGPTAccount,
           connection.chatgptPlanEligible == false,
           let fallback = settings.apiKeyFallbackConnection(for: connection) {
            return fallback
        }
        return connection
    }

    public init(
        settings: ProviderSettings,
        session: URLSession? = nil,
        chatGPTAccounts: ChatGPTAccountService? = nil
    ) {
        self.settings = settings
        self.session = session ?? Self.makeChatSession()
        self.chatGPTAccounts = chatGPTAccounts ?? .shared
    }

    public convenience init(session: URLSession? = nil) {
        self.init(settings: ProviderSettings.shared, session: session)
    }

    private static func makeChatSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = RemoteChatTimeout.idleSeconds()
        configuration.timeoutIntervalForResource = RemoteChatTimeout.resourceSeconds()
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func setActiveConnection(id: String?, modelID: String?) {
        activeConnectionID = id
        activeModelOverride = modelID
        isModelLoaded = false
        lastFunctionCalls = []
        lastTokenUsage = nil
        if let id, let connection = settings.connection(id: id) {
            restoreQueriedModels(from: connection)
        } else {
            queriedModels = []
        }
    }

    public func activate(
        connection: RemoteConnection,
        modelID: String? = nil
    ) {
        setActiveConnection(id: connection.id, modelID: modelID ?? connection.trimmedModel)
    }

    public func availableModels() -> [LLMModelOption] {
        if !queriedModels.isEmpty { return queriedModels }
        guard let connection = activeConnection else { return [] }
        let persisted = modelsFromPersistedList(for: connection)
        if !persisted.isEmpty { return persisted }
        let modelID = connection.trimmedModel
        guard !modelID.isEmpty else { return [] }
        return [LLMModelOption(id: modelID, displayName: modelID, estimatedMemoryGB: 0)]
    }

    public func queryModels(for connectionID: String) async throws -> [LLMModelOption] {
        guard let connection = settings.connection(id: connectionID) else {
            throw LLMServiceError.generationFailed("Connection not found.")
        }
        let adapter = settings.adapter(for: connection)
        guard adapter.isConfigured(connection: connection) else {
            throw LLMServiceError.generationFailed(adapter.configurationHint(connection: connection))
        }
        guard let modelsURL = adapter.buildModelsURL(baseURL: connection.trimmedBaseURL) else {
            throw LLMServiceError.generationFailed("Models URL is invalid.")
        }

        var models = try await fetchModels(at: modelsURL, connection: connection, adapter: adapter)
        let native = await lmStudioCapabilityModels(for: connection, adapter: adapter)
        if !native.models.isEmpty {
            models = LMStudioNativeModels.merge(models, native: native.models)
        }
        var ollama: Bool?
        if !native.isLMStudio && native.definiteNo { ollama = await answersOllamaVersion(connection, adapter: adapter) }
        if var updated = settings.connection(id: connectionID) {
            // The URL changed while this ran: these answers came from the old server.
            guard Self.sameServer(updated, connection) else {
                return Self.modelOptions(from: updated)
            }
            Self.recordDetection(native, ollama: ollama, on: &updated)
            updated.replaceAvailableModels(with: models)
            if updated != connection {
                settings.updateConnection(updated)
            }
        }
        return models.map { LLMModelOption(id: $0.id, displayName: $0.id, estimatedMemoryGB: 0) }
    }

    public func queryModels() async throws -> [LLMModelOption] {
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let models = try await queryModels(for: connection.id)
        queriedModels = models
        loadStatus = "Found \(models.count) remote model(s)"
        return models
    }

    /// Queries every enabled, configured remote connection and persists each
    /// connection's `availableModels` list. Failures are ignored so one offline
    /// endpoint does not block startup or discard existing cached model lists.
    public func refreshAllConnectionModels() async {
        let connectionIDs = settings.remoteConnections
            .filter { connection in
                connection.isEnabled && settings.adapter(for: connection).isConfigured(connection: connection)
            }
            .map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for connectionID in connectionIDs {
                group.addTask {
                    do {
                        _ = try await self.queryModels(for: connectionID)
                    } catch {
                        // Keep the last persisted model list when refresh fails.
                    }
                }
            }
        }
    }

    public func loadSelectedModel() async throws {
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let adapter = settings.adapter(for: connection)
        guard adapter.isConfigured(connection: connection) else {
            throw LLMServiceError.generationFailed(adapter.configurationHint(connection: connection))
        }
        guard adapter.buildChatURL(baseURL: connection.trimmedBaseURL) != nil else {
            throw LLMServiceError.generationFailed("Remote API URL is invalid.")
        }

        loadProgress = nil
        isModelLoaded = false

        if queriedModels.isEmpty {
            restoreQueriedModels(from: connection)
        }

        if queriedModels.isEmpty, let modelsURL = adapter.buildModelsURL(baseURL: connection.trimmedBaseURL) {
            do {
                var models = try await fetchModels(at: modelsURL, connection: connection, adapter: adapter)
                let native = await lmStudioCapabilityModels(for: connection, adapter: adapter)
                if !native.models.isEmpty {
                    models = LMStudioNativeModels.merge(models, native: native.models)
                }
                if var updated = settings.connection(id: connection.id), Self.sameServer(updated, connection) {
                    Self.recordDetection(native, ollama: nil, on: &updated)
                    updated.replaceAvailableModels(with: models)
                    if updated != connection {
                        settings.updateConnection(updated)
                    }
                    queriedModels = models.map { LLMModelOption(id: $0.id, displayName: $0.id, estimatedMemoryGB: 0) }
                } else if let updated = settings.connection(id: connection.id) {
                    // The URL changed while this ran: keep what is saved for the new one.
                    queriedModels = Self.modelOptions(from: updated)
                }
            } catch {
                if markReadyUsingPersistedModels(for: connection) { return }
                if OpenAICompatibleAPI.isPrivateNetworkHost(connection.trimmedBaseURL) {
                    loadStatus = "Remote endpoint ready (model list unavailable)"
                    isModelLoaded = true
                    return
                }
                throw error
            }
        }

        guard !activeModelID.isEmpty else {
            throw LLMServiceError.generationFailed("No model configured for \(connection.trimmedName).")
        }

        isModelLoaded = true
        loadStatus = "\(connection.trimmedName) · \(activeModelID) ready"
    }

    public func completeResponse(
        to prompt: String,
        history: [LLMChatTurn] = [],
        modelID: String? = nil
    ) async throws -> String {
        if !isModelLoaded { try await loadSelectedModel() }
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let adapter = settings.adapter(for: connection)

        let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: prompt)
        let raw = try await withPlanFallback(connection: connection, modelID: modelID ?? activeModelID) { target, model in
            try await self.completeNonStreaming(
                messages: messages,
                modelID: model,
                connection: target,
                adapter: self.settings.adapter(for: target)
            )
        }
        return adapter.sanitizeAssistantText(raw)
    }

    public func streamResponse(to prompt: String, history: [LLMChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard isModelLoaded else { throw LLMServiceError.modelNotLoaded }
                    guard let connection = activeConnection else {
                        throw LLMServiceError.generationFailed(settings.configurationHint)
                    }
                    let adapter = settings.adapter(for: connection)

                    let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: prompt)
                    var streamedAny = false

                    do {
                        _ = try await withPlanFallback(connection: connection, modelID: activeModelID) { target, model in
                            try await self.performStreamingRequest(
                                messages: messages,
                                modelID: model,
                                connection: target,
                                adapter: self.settings.adapter(for: target),
                                tools: []
                            ) { chunk in
                                streamedAny = true
                                continuation.yield(chunk)
                            }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw error
                    } catch {
                        if streamedAny { throw error }
                        // The plan route is streaming-only and already handled its
                        // own fallback; a second request would repeat the failure.
                        if connection.usesChatGPTAccount { throw error }
                        // An empty stream means the socket closed during prefill.
                        // Opening a second, non-streaming request just repeats the
                        // disconnect LM Studio logs as an empty completion.
                        if let serviceError = error as? LLMServiceError,
                           case .generationFailed(let message) = serviceError,
                           message.contains("empty streamed response") {
                            throw error
                        }
                        let fallback = try await completeNonStreaming(
                            messages: messages,
                            modelID: activeModelID,
                            connection: connection,
                            adapter: adapter,
                            tools: []
                        )
                        continuation.yield(adapter.sanitizeAssistantText(fallback))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    /// One agent round with optional native tool calling for supported adapters.
    public func agentRound(
        history: [LLMChatTurn],
        tools: [[String: Any]],
        toolNames: Set<String>,
        previousResponseID: String? = nil,
        functionCallOutputs: [EncodedFunctionCallOutput] = [],
        onToken: ((String) -> Void)? = nil,
        onReasoning: ((String) -> Void)? = nil,
        onWebSearch: (() -> Void)? = nil,
        onUsage: ((TokenUsage) -> Void)? = nil
    ) async throws -> (
        text: String,
        toolBlocks: [ToolCallBlock],
        responseID: String?,
        citations: [ChatWebSearchCitation]
    ) {
        if !isModelLoaded {
            try await loadSelectedModel()
        }
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let adapter = settings.adapter(for: connection, modelID: activeModelID)

        let messages = history.map(\.chatMessage)
        let useStructured = adapter.supportsStructuredTools && !tools.isEmpty
        var fullText = ""
        var reasoning = ""
        var collectedCitations: [ChatWebSearchCitation] = []
        var toolCallAccumulator = OpenAICompatibleAPI.StructuredToolCallAccumulator()
        var responsesToolAccumulator = OpenAIRequestCodec.ResponsesToolCallAccumulator()
        var roundResponseID: String?

        if useStructured {
            try await withPlanFallback(connection: connection, modelID: activeModelID) { target, model in
                let adapter = self.settings.adapter(for: target, modelID: model)
                let prepared = try self.prepareConversationRequest(
                    typedMessages: messages,
                    modelID: model,
                    connection: target,
                    adapter: adapter,
                    stream: true,
                    tools: tools,
                    previousResponseID: previousResponseID,
                    functionCallOutputs: functionCallOutputs
                )
                var request = URLRequest(url: prepared.url)
                request.httpMethod = "POST"
                request.timeoutInterval = Self.chatTimeout
                try await self.applyHeaders(to: &request, connection: target, adapter: adapter, streaming: true)
                request.httpBody = try JSONSerialization.data(withJSONObject: prepared.body)

                let (bytes, response, prefetchedError) = try await self.bytesWithRetry(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    var errorBody = prefetchedError ?? ""
                    if prefetchedError == nil {
                        for try await line in bytes.lines.prefix(20) { errorBody += line }
                    }
                    throw Self.httpError(statusCode: http.statusCode, body: errorBody, response: http, connection: target)
                }

                var accumulator = StreamTextAccumulator()
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let payload = StreamTextCodec.ssePayload(line) ?? (line.hasPrefix("{") ? line : nil) else {
                        if StreamTextCodec.isSSEDone(line) { break }
                        continue
                    }
                    if target.usesChatGPTAccount,
                       let planError = SubscriptionBillingPolicy.chatGPTStreamError(fromEventJSON: payload) {
                        throw planError
                    }
                    toolCallAccumulator.append(json: payload)
                    responsesToolAccumulator.append(json: payload)
                    if let thought = StreamTextCodec.classifyReasoning(payload) ?? OpenAICompatibleAPI.parseStreamingReasoning(payload),
                       !thought.isEmpty {
                        reasoning += thought
                        onReasoning?(thought)
                    }
                    if let event = OpenAIRequestCodec.parseResponsesStreamEvent(payload),
                       event.type.hasPrefix("response.") || event.type == "error" {
                        if let thought = event.reasoningDelta, !thought.isEmpty, event.type.contains("delta") {
                            reasoning += thought
                            onReasoning?(thought)
                        }
                        if let termination = event.termination ?? StreamTextCodecTermination.termination(in: payload) {
                            if termination.isFailure {
                                throw LLMServiceError.generationFailed(termination.userMessage)
                            }
                            if termination.isCutoff {
                                throw LLMServiceError.replyCutOff(termination.userMessage)
                            }
                        }
                        if let error = event.errorMessage {
                            throw LLMServiceError.generationFailed(error)
                        }
                        if event.isWebSearchActivity {
                            onWebSearch?()
                        }
                        if !event.citations.isEmpty {
                            var seen = Set(collectedCitations.map(\.url))
                            for citation in event.citations where seen.insert(citation.url).inserted {
                                collectedCitations.append(citation)
                            }
                        }
                        if let id = event.responseID, !id.isEmpty {
                            roundResponseID = id
                        }
                        if let usage = event.usage ?? TokenUsage.parse(json: payload) {
                            self.recordUsage(usage, notify: onUsage)
                        }
                        if let update = StreamTextCodec.update(fromResponses: event) ?? StreamTextCodec.classify(payload) {
                            let increment = accumulator.apply(update)
                            fullText = accumulator.text
                            if !increment.isEmpty {
                                onToken?(increment)
                            }
                        }
                        continue
                    }
                    if let usage = TokenUsage.parse(json: payload) {
                        self.recordUsage(usage, notify: onUsage)
                    }
                    if let update = StreamTextCodec.classify(payload) {
                        let increment = accumulator.apply(update)
                        fullText = accumulator.text
                        if !increment.isEmpty {
                            onToken?(increment)
                        }
                        continue
                    }
                    if let chunk = adapter.parseStreamingChunk(json: payload) {
                        let increment = accumulator.apply(.delta(chunk))
                        fullText = accumulator.text
                        if !increment.isEmpty {
                            onToken?(increment)
                        }
                    }
                    if let termination = StreamTextCodecTermination.termination(in: payload) {
                        if termination.isFailure {
                            throw LLMServiceError.generationFailed(termination.userMessage)
                        }
                        if termination.isCutoff {
                            throw LLMServiceError.replyCutOff(termination.userMessage)
                        }
                    }
                }
            }
            lastFunctionCalls = responsesToolAccumulator.finish()
            if lastFunctionCalls.isEmpty {
                lastFunctionCalls = toolCallAccumulator.encodedCalls()
            }
        } else {
            _ = try await performStreamingRequest(
                messages: messages.map { ["role": $0.role, "content": $0.content] },
                modelID: activeModelID,
                connection: connection,
                adapter: adapter,
                tools: [],
                onChunk: { chunk in
                    fullText += chunk
                    onToken?(chunk)
                },
                onReasoning: { thought in
                    reasoning += thought
                    onReasoning?(thought)
                }
            )
        }

        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let visible = adapter.sanitizeAssistantText(reasoning)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty {
                fullText = visible
            }
        }

        let fenced = adapter.parseToolBlocks(from: fullText, tags: toolNames)
        let structuredBlocks = toolCallAccumulator.finish()
        let responsesBlocks = responsesToolAccumulator.finish().compactMap { call -> ToolCallBlock? in
            var payload: [String: Any] = [
                "name": call.name,
                "arguments": call.arguments,
            ]
            if let callID = call.callID {
                payload["call_id"] = callID
            }
            return ToolCallParsing.toolBlock(from: payload)
        }
        let blocks = !responsesBlocks.isEmpty ? responsesBlocks
            : (structuredBlocks.isEmpty ? fenced : structuredBlocks)
        let textCitations = ChatWebSearchPolicy.parseCitations(from: fullText)
        var seen = Set(collectedCitations.map(\.url))
        for citation in textCitations where seen.insert(citation.url).inserted {
            collectedCitations.append(citation)
        }
        return (fullText, blocks, roundResponseID, collectedCitations)
    }

    /// Generates an image via the provider's `/images/generations` endpoint and
    /// returns the raw image bytes (downloading them when the provider responds
    /// with a URL instead of inline base64).
    public func generateImage(
        prompt: String,
        modelID: String? = nil,
        size: String = "1024x1024"
    ) async throws -> Data {
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let adapter = settings.adapter(for: connection)
        guard adapter.isConfigured(connection: connection) else {
            throw LLMServiceError.generationFailed(adapter.configurationHint(connection: connection))
        }
        let provider = connection.apiProvider
        guard let url = OpenAICompatibleAPI.buildImagesGenerationsURL(
            baseURL: connection.trimmedBaseURL,
            provider: provider
        ) else {
            throw LLMServiceError.generationFailed(
                "\(provider.displayName) does not support image generation."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Image generation is much slower than chat; allow several minutes.
        request.timeoutInterval = 300
        try await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)
        let body = OpenAICompatibleAPI.imageGenerationPayload(
            model: modelID ?? activeModelID,
            prompt: prompt,
            size: size
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.generationFailed("Invalid response from image provider.")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.generationFailed(
                OpenAICompatibleAPI.formatHTTPError(statusCode: http.statusCode, body: bodyText)
            )
        }

        switch try OpenAICompatibleAPI.parseImageGenerationResponse(data) {
        case .imageData(let imageData):
            return imageData
        case .remoteURL(let remoteURL):
            let (downloaded, downloadResponse) = try await session.data(from: remoteURL)
            if let http = downloadResponse as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw LLMServiceError.generationFailed(
                    "Could not download the generated image (HTTP \(http.statusCode))."
                )
            }
            return downloaded
        }
    }

    /// Edits an existing image via `/images/edits` (source image + prompt) and
    /// returns the resulting bytes. `dall-e-3` does not support this endpoint.
    public func editImage(
        prompt: String,
        imageData: Data,
        filename: String,
        modelID: String? = nil,
        size: String = "1024x1024"
    ) async throws -> Data {
        guard let connection = activeConnection else {
            throw LLMServiceError.generationFailed(settings.configurationHint)
        }
        let adapter = settings.adapter(for: connection)
        guard adapter.isConfigured(connection: connection) else {
            throw LLMServiceError.generationFailed(adapter.configurationHint(connection: connection))
        }
        let resolvedModel = modelID ?? activeModelID
        guard OpenAICompatibleAPI.isImageEditModel(resolvedModel) else {
            throw LLMServiceError.generationFailed(
                "\(resolvedModel) cannot edit an existing image. Choose gpt-image-1 or dall-e-2."
            )
        }
        let provider = connection.apiProvider
        guard let url = OpenAICompatibleAPI.buildImagesEditsURL(
            baseURL: connection.trimmedBaseURL,
            provider: provider
        ) else {
            throw LLMServiceError.generationFailed(
                "\(provider.displayName) does not support image editing."
            )
        }

        let wantsSquare = ((resolvedModel.lowercased() as NSString).lastPathComponent.hasPrefix("dall-e-2"))
        let pngData: Data
        do {
            pngData = try ImageFileCodec.pngData(from: imageData, square: wantsSquare)
        } catch {
            throw LLMServiceError.generationFailed(
                "Could not read \(filename) for editing. Try a PNG, JPEG, or HEIC image."
            )
        }
        let editSize = OpenAICompatibleAPI.isGPTImageFamily(resolvedModel) ? "auto" : size
        let form = OpenAICompatibleAPI.imageEditFormBody(
            model: resolvedModel,
            prompt: prompt,
            imageData: pngData,
            filename: "image.png",
            mimeType: "image/png",
            size: editSize
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        try await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.generationFailed("Invalid response from image provider.")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.generationFailed(
                OpenAICompatibleAPI.formatHTTPError(statusCode: http.statusCode, body: bodyText)
            )
        }

        switch try OpenAICompatibleAPI.parseImageGenerationResponse(data) {
        case .imageData(let imageData):
            return imageData
        case .remoteURL(let remoteURL):
            let (downloaded, downloadResponse) = try await session.data(from: remoteURL)
            if let http = downloadResponse as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw LLMServiceError.generationFailed(
                    "Could not download the edited image (HTTP \(http.statusCode))."
                )
            }
            return downloaded
        }
    }

    public func testConnection(connectionID: String, prompt: String = "Say hello in one short sentence.") async throws -> String {
        guard let connection = settings.connection(id: connectionID) else {
            throw LLMServiceError.generationFailed("Connection not found.")
        }
        activate(connection: connection, modelID: connection.trimmedModel)
        try await loadSelectedModel()
        return try await completeResponse(to: prompt, history: [])
    }

    private var activeModelID: String {
        OpenAICompatibleAPI.resolvedModelID(
            requested: selectedModelID,
            available: queriedModels.map(\.id)
        )
    }

    private func modelsFromPersistedList(for connection: RemoteConnection) -> [LLMModelOption] {
        let ids = connection.availableModels.filter { !$0.isEmpty }
        if !ids.isEmpty {
            return ids.map { LLMModelOption(id: $0, displayName: $0, estimatedMemoryGB: 0) }
        }
        let fallback = connection.trimmedModel
        guard !fallback.isEmpty else { return [] }
        return [LLMModelOption(id: fallback, displayName: fallback, estimatedMemoryGB: 0)]
    }

    private func restoreQueriedModels(from connection: RemoteConnection) {
        queriedModels = modelsFromPersistedList(for: connection)
    }

    @discardableResult
    private func markReadyUsingPersistedModels(for connection: RemoteConnection) -> Bool {
        restoreQueriedModels(from: connection)
        guard !queriedModels.isEmpty else { return false }
        isModelLoaded = true
        loadStatus = "\(connection.trimmedName) · \(activeModelID) ready"
        return true
    }

    private func fetchModels(
        at url: URL,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter
    ) async throws -> [RemoteModelDescriptor] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        try await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.generationFailed("Invalid response from remote provider.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.generationFailed(
                OpenAICompatibleAPI.formatHTTPError(statusCode: http.statusCode, body: body)
            )
        }
        if let descriptors = try? OpenAICompatibleAPI.parseModelsResponseDescriptors(data),
           !descriptors.isEmpty {
            return descriptors
        }
        return try adapter.parseModelsResponse(data: data).map { RemoteModelDescriptor(id: $0) }
    }

    /// Asks the server what it is (LM Studio's own model lists, then Ollama's `/api/version`) and
    /// saves it on the connection, without a full model refresh. Used once per launch, when a
    /// connection is saved and before a tool test. Returns whether it is LM Studio (nil when the
    /// server couldn't be told, e.g. it is unreachable).
    @discardableResult
    public func detectServer(for connectionID: String) async -> Bool? {
        guard let connection = settings.connection(id: connectionID) else { return nil }
        guard connection.mayServeLMStudio else { return connection.currentLMStudioDetection }
        let adapter = settings.adapter(for: connection)
        let native = await lmStudioCapabilityModels(for: connection, adapter: adapter)
        var ollama: Bool?
        if !native.isLMStudio && native.definiteNo { ollama = await answersOllamaVersion(connection, adapter: adapter) }
        guard var updated = settings.connection(id: connectionID),
              RemoteConnection.detectionKey(updated.trimmedBaseURL) == RemoteConnection.detectionKey(connection.trimmedBaseURL) else { return nil }
        Self.recordDetection(native, ollama: ollama, on: &updated)
        if native.isLMStudio, !native.models.isEmpty, !updated.availableModels.isEmpty {
            let known = native.models.filter { updated.availableModels.contains($0.id) }
            if !known.isEmpty {
                var tools = updated.modelToolSupport ?? [:]
                for model in known { if let t = model.supportsTools { tools[model.id] = t } }
                updated.modelToolSupport = tools
            }
        }
        if updated != connection { settings.updateConnection(updated) }
        return updated.currentLMStudioDetection
    }

    /// Checks every enabled connection that may be LM Studio and has no answer for its current
    /// URL yet, all at once, e.g. rows saved by older builds (Standard on :1234 used to count as
    /// LM Studio by port).
    public func detectServersIfNeeded() async {
        let ids = settings.remoteConnections
            .filter { $0.isEnabled && $0.mayServeLMStudio && !$0.detectionIsCurrent }
            .map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.detectServer(for: id) }
            }
        }
    }

    /// LM Studio's list sticks until the server definitely says otherwise: both of LM Studio's
    /// lists answered 404/405, or with something that isn't LM Studio's list. An error status
    /// (401, 403, 408, 429, 5xx), a timeout or an unreachable server changes nothing.
    static func recordDetection(
        _ native: (models: [RemoteModelDescriptor], isLMStudio: Bool, definiteNo: Bool),
        ollama: Bool?,
        on connection: inout RemoteConnection
    ) {
        if native.isLMStudio {
            connection.recordServer(isLMStudio: true, isOllama: false)
        } else if native.definiteNo {
            connection.recordServer(isLMStudio: false, isOllama: ollama)
        }
    }

    /// Whether `current` still points at the server `asked` was asked about.
    static func sameServer(_ current: RemoteConnection, _ asked: RemoteConnection) -> Bool {
        RemoteConnection.detectionKey(current.trimmedBaseURL) == RemoteConnection.detectionKey(asked.trimmedBaseURL)
    }

    static func modelOptions(from connection: RemoteConnection) -> [LLMModelOption] {
        connection.availableModels.map { LLMModelOption(id: $0, displayName: $0, estimatedMemoryGB: 0) }
    }

    /// `GET /api/v1/models`, then `/api/v0/models` (then `/v1/models` for metadata on a known
    /// LM Studio). Best effort: an older server 404s one of them. `isLMStudio` is true when the
    /// answer was LM Studio's own list, whatever the port; `definiteNo` when both of LM Studio's
    /// lists answered (404/405, or another server's reply) without being LM Studio's.
    private func lmStudioCapabilityModels(
        for connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter
    ) async -> (models: [RemoteModelDescriptor], isLMStudio: Bool, definiteNo: Bool) {
        var nativeAnswers = 0
        var nativeAsked = 0
        for url in LMStudioNativeModels.nativeListURLs(for: connection) {
            let isNative = url.path.hasSuffix("/api/v1/models") || url.path.hasSuffix("/api/v0/models")
            if !isNative, nativeAsked > 0 {
                // Both lists said "not LM Studio": its plain /v1/models says nothing about tools.
                if nativeAnswers == nativeAsked { return ([], false, true) }
                // Neither answered (off, timed out, or an error status): don't wait a third time.
                if nativeAnswers == 0 { return ([], false, false) }
            }
            let fetched = await fetchNativeModels(at: url, connection: connection, adapter: adapter)
            if fetched.isLMStudio { return (fetched.models, true, false) }
            // A list with tool information on LM Studio's path (an older LM Studio's v0 rows) is
            // used on a known LM Studio, and isn't a "no".
            if isNative, fetched.models.contains(where: { $0.supportsTools != nil }) { return (fetched.models, false, false) }
            if isNative {
                nativeAsked += 1
                if fetched.answered { nativeAnswers += 1 }
            } else if !fetched.models.isEmpty {
                return (fetched.models, false, false)
            }
        }
        return ([], false, nativeAsked > 0 && nativeAnswers == nativeAsked)
    }

    /// LM Studio's own model list. Best effort: an older LM Studio, or another server on the
    /// network, simply has no answer. `answered` is true only for a reply that says something
    /// about the server: 404/405, or a successful reply. 401, 403, 408, 429 and 5xx (an API key,
    /// a proxy in front of a stopped server, a server starting up) are no answer.
    private func fetchNativeModels(
        at url: URL,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter
    ) async -> (models: [RemoteModelDescriptor], isLMStudio: Bool, answered: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        guard (try? await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)) != nil,
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return ([], false, false) }
        guard (200...299).contains(http.statusCode) else {
            return ([], false, http.statusCode == 404 || http.statusCode == 405)
        }
        let isLMStudio = LMStudioNativeModels.isLMStudioList(data)
        guard let parsed = try? OpenAIRequestCodec.parseModelsList(data) else { return ([], isLMStudio, true) }
        // Another app's plain list is only useful on a connection already known to be LM Studio.
        guard isLMStudio || connection.servesLMStudioTools else { return ([], false, true) }
        return (LMStudioNativeModels.includingAliases(parsed, json: data), isLMStudio, true)
    }

    /// Ollama answers `GET /api/version` with `{"version": "…"}`. Nil when the server didn't answer.
    private func answersOllamaVersion(_ connection: RemoteConnection, adapter: RemoteLLMProtocolAdapter) async -> Bool? {
        guard let url = LMStudioNativeModels.rootURL(for: connection, suffix: "/api/version") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        guard (try? await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)) != nil,
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["version"] is String
    }

    private func validateModelsList(
        at url: URL,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter
    ) async throws {
        _ = try await fetchModels(at: url, connection: connection, adapter: adapter)
        loadStatus = "Remote provider reachable"
    }

    private func prepareConversationRequest(
        messages: [[String: String]],
        modelID: String,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter,
        stream: Bool,
        tools: [[String: Any]],
        previousResponseID: String? = nil,
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) throws -> (url: URL, body: [String: Any], api: OpenAIConversationAPI) {
        try prepareConversationRequest(
            typedMessages: ChatCompletionMessage.from(messages),
            modelID: modelID,
            connection: connection,
            adapter: adapter,
            stream: stream,
            tools: tools,
            previousResponseID: previousResponseID,
            functionCallOutputs: functionCallOutputs
        )
    }

    private func prepareConversationRequest(
        typedMessages: [ChatCompletionMessage],
        modelID: String,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter,
        stream: Bool,
        tools: [[String: Any]],
        previousResponseID: String? = nil,
        functionCallOutputs: [EncodedFunctionCallOutput] = []
    ) throws -> (url: URL, body: [String: Any], api: OpenAIConversationAPI) {
        if connection.usesChatGPTAccount {
            return try prepareChatGPTPlanRequest(
                typedMessages: typedMessages,
                modelID: modelID,
                connection: connection,
                tools: tools,
                functionCallOutputs: functionCallOutputs
            )
        }
        let hasTools = !tools.isEmpty
        let hasHostedWebSearch = OpenAIRequestCodec.containsHostedWebSearch(tools)
        // Automatic keeps the routing Odyssey always had; an explicit choice on the connection wins.
        let useResponses = connection.usesResponsesAPI(
            model: modelID,
            hasTools: hasTools,
            hasHostedWebSearch: hasHostedWebSearch
        )
        let explicitAPI = connection.offersAPIChoice && connection.apiChoice != .automatic
        guard var url = adapter.buildChatURL(
            baseURL: connection.trimmedBaseURL,
            model: modelID,
            hasTools: hasTools
        ) else {
            throw LLMServiceError.generationFailed("Remote API URL is invalid.")
        }
        if useResponses, let responsesURL = OpenAICompatibleAPI.buildResponsesURL(baseURL: connection.trimmedBaseURL) {
            url = responsesURL
        } else if explicitAPI, let chatURL = adapter.buildChatURL(baseURL: connection.trimmedBaseURL) {
            url = chatURL
        }
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: modelID,
            backend: .remote,
            live: connection.liveCapabilities(for: modelID)
        )
        let stored = ModelGenerationSettings.options(connectionID: connection.id, modelID: modelID)
        let contextLimit = ModelCapabilityCatalog.clampContextTokens(
            stored.contextWindowTokens,
            capabilities: caps
        ) ?? caps.contextWindowTokens
        let reserved = OpenAIRequestCodec.reservedOutputTokens(
            contextWindowTokens: contextLimit,
            maxOutputTokens: caps.maxOutputTokens
        )
        // Tool schemas are rendered into the prompt too, so the history gets what is left.
        let historyWindow = max(contextLimit - OpenAIRequestCodec.estimatedTokens(inTools: tools), 1)
        let truncated = OpenAIRequestCodec.truncateMessages(
            typedMessages,
            contextWindowTokens: historyWindow,
            reservedOutputTokens: reserved
        )
        let remember = ModelOptionsFormatting.resolvedRememberThinking(
            options: stored,
            capabilities: caps
        )
        // previous_response_id only means something on Responses; on Chat Completions it would
        // shrink the history to the last message.
        let continueID = remember && useResponses ? previousResponseID : nil
        let requestMessages: [ChatCompletionMessage]
        if continueID != nil, !functionCallOutputs.isEmpty {
            requestMessages = []
        } else if continueID != nil, let last = truncated.last, last.role == "user" {
            requestMessages = [last]
        } else {
            requestMessages = truncated
        }
        let stringMessages = requestMessages.map { ["role": $0.role, "content": $0.content] }
        let currentCalls = functionCallOutputs.isEmpty ? [] : lastFunctionCalls
        var body: [String: Any]
        if useResponses {
            body = OpenAIRequestCodec.responsesPayload(
                model: modelID,
                typedMessages: requestMessages,
                stream: stream,
                tools: tools,
                previousResponseID: continueID,
                functionCalls: currentCalls,
                functionCallOutputs: functionCallOutputs
            )
        } else if explicitAPI {
            body = adapter.chatPayload(model: modelID, messages: stringMessages, stream: stream, tools: tools)
        } else {
            body = adapter.requestBody(
                model: modelID,
                messages: stringMessages,
                stream: stream,
                tools: tools,
                baseURL: connection.trimmedBaseURL,
                previousResponseID: continueID,
                functionCallOutputs: functionCallOutputs
            )
        }
        if !useResponses {
            // History already carries prior tool_calls / tool_call_id. Only attach
            // lastFunctionCalls when this request also has matching outputs — a
            // leftover last-call list with no tool messages 400s OpenAI-compatible servers.
            let typed = try Self.checkedToolRounds(ChatCompletionToolRoundTrip.applying(
                to: requestMessages,
                functionCalls: currentCalls,
                functionCallOutputs: functionCallOutputs
            ))
            body["messages"] = typed.map(\.jsonObject)
        } else {
            try Self.checkResponsesToolRounds(in: &body)
        }
        let api: OpenAIConversationAPI = useResponses ? .responses : .chatCompletions
        OpenAIRequestCodec.applyGenerationOptions(
            stored,
            to: &body,
            model: modelID,
            api: api,
            live: connection.liveCapabilities(for: modelID)
        )
        return (url, body, api)
    }

    /// ChatGPT plan usage: Responses only, `stream:true`, `store:false`, full
    /// history in `input`, and none of the fields the plan route rejects.
    private func prepareChatGPTPlanRequest(
        typedMessages: [ChatCompletionMessage],
        modelID: String,
        connection: RemoteConnection,
        tools: [[String: Any]],
        functionCallOutputs: [EncodedFunctionCallOutput]
    ) throws -> (url: URL, body: [String: Any], api: OpenAIConversationAPI) {
        guard let url = OpenAICompatibleAPI.buildResponsesURL(baseURL: connection.trimmedBaseURL) else {
            throw LLMServiceError.generationFailed("Remote API URL is invalid.")
        }
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: modelID,
            backend: .remote,
            live: connection.liveCapabilities(for: modelID)
        )
        let stored = ModelGenerationSettings.options(connectionID: connection.id, modelID: modelID)
        let contextLimit = ModelCapabilityCatalog.clampContextTokens(
            stored.contextWindowTokens,
            capabilities: caps
        ) ?? caps.contextWindowTokens
        let reserved = OpenAIRequestCodec.reservedOutputTokens(
            contextWindowTokens: contextLimit,
            maxOutputTokens: caps.maxOutputTokens
        )
        // Tool schemas are rendered into the prompt too, so the history gets what is left.
        let historyWindow = max(contextLimit - OpenAIRequestCodec.estimatedTokens(inTools: tools), 1)
        let truncated = OpenAIRequestCodec.truncateMessages(
            typedMessages,
            contextWindowTokens: historyWindow,
            reservedOutputTokens: reserved
        )
        var body = OpenAIRequestCodec.chatGPTPlanPayload(
            model: modelID,
            typedMessages: truncated,
            tools: tools,
            functionCalls: functionCallOutputs.isEmpty ? [] : lastFunctionCalls,
            functionCallOutputs: functionCallOutputs
        )
        // Reasoning effort is allowed; everything else options add is stripped again.
        OpenAIRequestCodec.applyGenerationOptions(
            stored,
            to: &body,
            model: modelID,
            api: .responses,
            live: connection.liveCapabilities(for: modelID)
        )
        OpenAIRequestCodec.applyChatGPTPlanRequirements(to: &body)
        try Self.checkResponsesToolRounds(in: &body)
        return (url, body, .responses)
    }

    /// Pre-send check for Chat Completions: the messages must never end in an assistant turn
    /// with `tool_calls`. LM Studio and llama.cpp read a trailing assistant as a prefill and
    /// answer "Cannot continue an assistant message that contains tool calls." Misplaced calls
    /// move in front of their results and unanswered trailing calls are dropped; anything still
    /// wrong fails here with a clear message instead of a server 400.
    static func checkedToolRounds(_ messages: [ChatCompletionMessage]) throws -> [ChatCompletionMessage] {
        let repaired = ToolRoundRequestGuard.repaired(messages)
        if let problem = ToolRoundRequestGuard.problem(in: repaired) {
            throw LLMServiceError.generationFailed(problem)
        }
        return repaired
    }

    /// Pre-send check for Responses: `input` must never end in a `function_call` with no output.
    static func checkResponsesToolRounds(in body: inout [String: Any]) throws {
        guard let input = body["input"] as? [[String: Any]] else { return }
        let repaired = ToolRoundRequestGuard.repairedResponsesInput(input)
        if let problem = ToolRoundRequestGuard.problem(inResponsesInput: repaired) {
            throw LLMServiceError.generationFailed(problem)
        }
        body["input"] = repaired
    }

    /// Plan errors become `SubscriptionBillingError` so callers can fall back.
    private static func httpError(
        statusCode: Int,
        body: String,
        response: HTTPURLResponse,
        connection: RemoteConnection
    ) -> Error {
        if connection.usesChatGPTAccount {
            let requestID = response.value(forHTTPHeaderField: "x-request-id")
                ?? response.value(forHTTPHeaderField: "openai-request-id")
            return SubscriptionBillingPolicy.classifyChatGPT(
                statusCode: statusCode,
                body: Data(body.utf8),
                requestID: requestID
            )
        }
        return LLMServiceError.generationFailed(
            OpenAICompatibleAPI.formatHTTPError(statusCode: statusCode, body: body)
        )
    }

    /// Runs `operation` on a ChatGPT plan connection. On
    /// `subscription_sharing_user_not_eligible` it turns plan usage off and
    /// retries once on the matching API-key connection; other plan errors
    /// surface their documented recovery message. OpenAI never switches
    /// billing itself, so this is the app's explicit, visible fallback.
    private func withPlanFallback<T>(
        connection: RemoteConnection,
        modelID: String,
        _ operation: (RemoteConnection, String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(connection, modelID)
        } catch let billing as SubscriptionBillingError {
            guard connection.usesChatGPTAccount, billing.fallsBackToAPIKey else {
                throw LLMServiceError.generationFailed(billing.errorDescription ?? billing.userMessage)
            }
            let fallback = settings.apiKeyFallbackConnection(for: connection)
            let notice = SubscriptionBillingPolicy.fallbackNotice(hasAPIKey: fallback != nil)
            chatGPTAccounts.markPlanUnavailable(
                connectionID: connection.id,
                providerSettings: settings,
                message: notice
            )
            guard let fallback else {
                throw LLMServiceError.generationFailed(notice)
            }
            let fallbackModel = fallback.availableModels.isEmpty || fallback.availableModels.contains(modelID)
                ? modelID
                : fallback.trimmedModel
            return try await operation(fallback, fallbackModel)
        }
    }

    @discardableResult
    private func performStreamingRequest(
        messages: [[String: String]],
        modelID: String,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter,
        tools: [[String: Any]] = [],
        previousResponseID: String? = nil,
        functionCallOutputs: [EncodedFunctionCallOutput] = [],
        onChunk: (String) -> Void,
        onReasoning: ((String) -> Void)? = nil
    ) async throws -> Bool {
        let prepared = try prepareConversationRequest(
            messages: messages,
            modelID: modelID,
            connection: connection,
            adapter: adapter,
            stream: true,
            tools: tools,
            previousResponseID: previousResponseID,
            functionCallOutputs: functionCallOutputs
        )
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.chatTimeout
        try await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: prepared.body)

        let (bytes, response, prefetchedError) = try await bytesWithRetry(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errorBody = prefetchedError ?? ""
            if prefetchedError == nil {
                for try await line in bytes.lines.prefix(20) {
                    errorBody += line
                }
            }
            throw Self.httpError(statusCode: http.statusCode, body: errorBody, response: http, connection: connection)
        }

        var yielded = false
        var accumulator = StreamTextAccumulator()
        var reasoning = ""
        var sawResponsesEvent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = StreamTextCodec.ssePayload(line) ?? (line.hasPrefix("{") ? line : nil) else {
                if StreamTextCodec.isSSEDone(line) { break }
                continue
            }

            if connection.usesChatGPTAccount,
               let planError = SubscriptionBillingPolicy.chatGPTStreamError(fromEventJSON: payload) {
                throw planError
            }
            if let event = OpenAIRequestCodec.parseResponsesStreamEvent(payload),
               event.type.hasPrefix("response.") || event.type == "error" {
                sawResponsesEvent = true
                if let thought = event.reasoningDelta, !thought.isEmpty, event.type.contains("delta") {
                    reasoning += thought
                    onReasoning?(thought)
                }
                if let usage = event.usage ?? TokenUsage.parse(json: payload) {
                    recordUsage(usage)
                }
                if let update = StreamTextCodec.update(fromResponses: event) ?? StreamTextCodec.classify(payload) {
                    let increment = accumulator.apply(update)
                    if !increment.isEmpty {
                        yielded = true
                        onChunk(increment)
                    }
                }
                if let termination = event.termination ?? StreamTextCodecTermination.termination(in: payload) {
                    if termination.isFailure {
                        throw LLMServiceError.generationFailed(termination.userMessage)
                    }
                    if termination.isCutoff {
                        throw LLMServiceError.replyCutOff(termination.userMessage)
                    }
                }
                if let error = event.errorMessage {
                    throw LLMServiceError.generationFailed(error)
                }
                continue
            }

            if let usage = TokenUsage.parse(json: payload) {
                recordUsage(usage)
            }
            if let thought = StreamTextCodec.classifyReasoning(payload) ?? OpenAICompatibleAPI.parseStreamingReasoning(payload),
               !thought.isEmpty {
                reasoning += thought
                onReasoning?(thought)
            }

            if let update = StreamTextCodec.classify(payload) {
                let increment = accumulator.apply(update)
                if !increment.isEmpty {
                    yielded = true
                    onChunk(increment)
                }
            } else if let rawChunk = adapter.parseStreamingChunk(json: payload), !rawChunk.isEmpty {
                let increment = accumulator.apply(.delta(rawChunk))
                if !increment.isEmpty {
                    yielded = true
                    onChunk(increment)
                }
            }
            if let termination = StreamTextCodecTermination.termination(in: payload) {
                if termination.isFailure {
                    throw LLMServiceError.generationFailed(termination.userMessage)
                }
                if termination.isCutoff {
                    throw LLMServiceError.replyCutOff(termination.userMessage)
                }
            }
        }

        // A reasoning model can finish with thoughts only. Surface that text
        // instead of treating the stream as empty and opening a second request.
        if !yielded {
            let visible = adapter.sanitizeAssistantText(reasoning)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty {
                onChunk(visible)
                yielded = true
            }
        }

        if !yielded, !sawResponsesEvent {
            throw LLMServiceError.generationFailed("Remote provider returned an empty streamed response.")
        }
        return yielded
    }

    private func completeNonStreaming(
        messages: [[String: String]],
        modelID: String,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter,
        tools: [[String: Any]] = []
    ) async throws -> String {
        if connection.usesChatGPTAccount {
            // The plan route only accepts `stream:true`; collect the stream.
            var text = ""
            _ = try await performStreamingRequest(
                messages: messages,
                modelID: modelID,
                connection: connection,
                adapter: adapter,
                tools: tools
            ) { text += $0 }
            return text
        }
        let prepared = try prepareConversationRequest(
            messages: messages,
            modelID: modelID,
            connection: connection,
            adapter: adapter,
            stream: false,
            tools: tools
        )
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.chatTimeout
        try await applyHeaders(to: &request, connection: connection, adapter: adapter, streaming: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: prepared.body)

        let (data, response) = try await dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.generationFailed("Invalid response from remote provider.")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMServiceError.generationFailed(
                OpenAICompatibleAPI.formatHTTPError(statusCode: http.statusCode, body: bodyText)
            )
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = TokenUsage.parse(from: object) {
            recordUsage(usage)
        }
        return try adapter.parseCompletionResponse(data: data)
    }

    private func recordUsage(_ usage: TokenUsage, notify: ((TokenUsage) -> Void)? = nil) {
        lastTokenUsage = usage
        notify?(usage)
    }

    /// `errorBody` is set when the error reply was already read to decide on a retry.
    private func bytesWithRetry(
        for request: URLRequest
    ) async throws -> (bytes: URLSession.AsyncBytes, response: URLResponse, errorBody: String?) {
        var attempt = 1
        while true {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  HTTPRetryPolicy.shouldRetry(statusCode: http.statusCode, attempt: attempt, receivedStreamBytes: false)
            else {
                return (bytes, response, nil)
            }
            var errorBody = ""
            for try await line in bytes.lines.prefix(20) { errorBody += line }
            guard HTTPRetryPolicy.shouldRetry(
                statusCode: http.statusCode,
                attempt: attempt,
                receivedStreamBytes: false,
                body: Data(errorBody.utf8)
            ) else {
                return (bytes, response, errorBody)
            }
            let delay = HTTPRetryPolicy.delaySeconds(
                attempt: attempt,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                retryAfterMilliseconds: http.value(forHTTPHeaderField: "retry-after-ms")
            )
            attempt += 1
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func dataWithRetry(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        var attempt = 1
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  HTTPRetryPolicy.shouldRetry(statusCode: http.statusCode, attempt: attempt, receivedStreamBytes: false, body: data)
            else {
                return (data, response)
            }
            let delay = HTTPRetryPolicy.delaySeconds(
                attempt: attempt,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                retryAfterMilliseconds: http.value(forHTTPHeaderField: "retry-after-ms")
            )
            attempt += 1
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func applyHeaders(
        to request: inout URLRequest,
        connection: RemoteConnection,
        adapter: RemoteLLMProtocolAdapter,
        streaming: Bool
    ) async throws {
        for (key, value) in adapter.requestHeaders(connection: connection, streaming: streaming) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if connection.usesChatGPTAccount {
            let token = try await chatGPTAccounts.validAccessToken(for: connection)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}
