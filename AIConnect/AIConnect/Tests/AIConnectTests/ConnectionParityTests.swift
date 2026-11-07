// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

final class MemorySecureStore: TokenSecureStore {
    var values: [String: Data] = [:]
    func read(account: String) -> Data? { values[account] }
    func write(_ data: Data, account: String) { values[account] = data }
    func remove(account: String) { values[account] = nil }
}

/// Records requests made by RemoteLLMService and answers with one SSE stream.
final class ServiceWireStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(url: String, body: [String: Any])] = []
    nonisolated(unsafe) static var reply = ""
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ServiceWireStub.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
        }
        Self.requests.append((request.url?.absoluteString ?? "", (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// User report: "An AI Odyssey ... has the responses protocol for OpenAI ... and the ability to select the
/// thinking and reasoning levels. So please clean up the gap." These settings live on the shared
/// connection so every host app reads the same thing.
final class ConnectionParityTests: XCTestCase {
    func testOldSavedConnectionsDecodeAsAutomatic() throws {
        let saved = RemoteConnection(name: "OpenAI", apiBaseURL: "https://api.openai.com/v1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "openAIAPI")
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.openAIAPI)
        XCTAssertEqual(decoded.apiChoice, .automatic)
    }

    func testAutomaticKeepsOdysseysRouting() {
        let cases: [(String, String, Bool)] = [
            ("https://api.openai.com/v1", "gpt-6-astra", true),
            ("https://api.openai.com/v1", "gpt-4o", false),
            ("https://api.openai.com/v1", "gpt-4o", true),
            ("https://api.x.ai/v1", "grok-4.7", true),
            ("https://openrouter.ai/api/v1", "gpt-6-astra", true),
            ("http://localhost:1234/v1", "qwen3-coder", true),
        ]
        for (url, model, tools) in cases {
            let c = RemoteConnection(name: "c", apiBaseURL: url)
            XCTAssertEqual(c.usesResponsesAPI(model: model, hasTools: tools),
                           OpenAIRequestCodec.shouldUseResponsesAPI(baseURL: url, model: model, hasTools: tools), "\(url) \(model)")
        }
    }

    func testExplicitChoiceOverridesRouting() {
        var custom = RemoteConnection(name: "Proxy", apiBaseURL: "https://llm.example.test/v1")
        XCTAssertFalse(custom.usesResponsesAPI(model: "gpt-6-astra", hasTools: true))
        custom.openAIAPI = .responses
        XCTAssertTrue(custom.usesResponsesAPI(model: "gpt-6-astra", hasTools: true))
        XCTAssertTrue(custom.usesResponsesAPI(model: "anything", hasTools: false))

        var openAI = RemoteConnection(name: "OpenAI", apiBaseURL: "https://api.openai.com/v1")
        openAI.openAIAPI = .chatCompletions
        XCTAssertFalse(openAI.usesResponsesAPI(model: "gpt-6-astra", hasTools: true))

        var gemini = RemoteConnection.geminiPreset()
        gemini.openAIAPI = .responses
        XCTAssertFalse(gemini.usesResponsesAPI(model: "gemini-3-pro", hasTools: true), "only OpenAI-style connections have a choice")
        XCTAssertFalse(gemini.offersAPIChoice)
        XCTAssertTrue(openAI.offersAPIChoice)

        var chatGPT = RemoteConnection.chatGPTPreset()
        chatGPT.chatgptIssuedClientID = "oaiapp_test"
        chatGPT.openAIAPI = .chatCompletions
        XCTAssertTrue(chatGPT.usesResponsesAPI(model: "gpt-6.1-sol", hasTools: true), "ChatGPT plan usage is Responses only")
        XCTAssertFalse(chatGPT.offersAPIChoice)
    }

    func testRequestPlanCarriesTheChosenThinkingLevel() {
        let openAI = RemoteConnection(id: "plan-openai", name: "OpenAI", apiBaseURL: "https://api.openai.com/v1")
        defer { ModelGenerationSettings.removeOptions(connectionID: openAI.id) }
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .low, maxOutputTokens: 9000, contextWindowTokens: 64_000),
                                           connectionID: openAI.id, modelID: "gpt-6-astra")
        let plan = ConnectionRequestPlan.resolve(connection: openAI, modelID: "gpt-6-astra", hasTools: true)
        XCTAssertTrue(plan.usesResponsesAPI)
        XCTAssertEqual(plan.reasoningEffort, .low)
        XCTAssertEqual(plan.maxOutputTokens, 9000)
        XCTAssertEqual(plan.contextWindowTokens, 64_000)
        XCTAssertTrue(plan.rememberThinking)

        // A level the model doesn't take falls back to the model's default instead of a 400.
        let xai = RemoteConnection(id: "plan-xai", name: "xAI", apiBaseURL: "https://api.x.ai/v1")
        defer { ModelGenerationSettings.removeOptions(connectionID: xai.id) }
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .max), connectionID: xai.id, modelID: "grok-4.7")
        XCTAssertEqual(ConnectionRequestPlan.resolve(connection: xai, modelID: "grok-4.7", hasTools: true).reasoningEffort, .high)

        // No thinking control: nothing is sent.
        let plain = ConnectionRequestPlan.resolve(connection: openAI, modelID: "gpt-4o", hasTools: false)
        XCTAssertNil(plain.reasoningEffort)
        XCTAssertFalse(plain.usesResponsesAPI)
        XCTAssertFalse(plain.rememberThinking)

        // Forced Chat Completions keeps the thinking level as reasoning_effort.
        var forced = openAI
        forced.openAIAPI = .chatCompletions
        let chat = ConnectionRequestPlan.resolve(connection: forced, modelID: "gpt-6-astra", hasTools: true)
        XCTAssertFalse(chat.usesResponsesAPI)
        XCTAssertEqual(chat.reasoningEffort, .low)
        XCTAssertTrue(chat.usesMaxCompletionTokens)
        XCTAssertFalse(chat.rememberThinking, "encrypted reasoning only exists on Responses")

        // ChatGPT plan route rejects max_output_tokens and include.
        var chatGPT = RemoteConnection.chatGPTPreset()
        chatGPT.chatgptIssuedClientID = "oaiapp_test"
        let planRoute = ConnectionRequestPlan.resolve(connection: chatGPT, modelID: "gpt-6.1-sol", hasTools: true)
        XCTAssertTrue(planRoute.usesResponsesAPI)
        XCTAssertNil(planRoute.maxOutputTokens)
        XCTAssertFalse(planRoute.rememberThinking)
        XCTAssertNotNil(planRoute.reasoningEffort)

        var lm = RemoteConnection.lmStudioPreset()
        lm.id = "plan-lm"
        lm.liveModelCapabilities = [
            "qwen3.8-flash-next": LiveModelCapabilities(
                contextWindowTokens: 8192,
                reasoningEfforts: [.low, .medium, .high],
                defaultReasoningEffort: .medium
            ),
        ]
        let lmPlan = ConnectionRequestPlan.resolve(connection: lm, modelID: "qwen3.8-flash-next", hasTools: true)
        XCTAssertNil(lmPlan.reasoningEffort, "LM Studio's listed default is not copied; the server applies the model's own")
        XCTAssertNil(lmPlan.contextWindowTokens, "no stored context override")
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "qwen3.8-flash-next",
            backend: .remote,
            live: lm.liveCapabilities(for: "qwen3.8-flash-next")
        )
        XCTAssertEqual(caps.contextWindowTokens, 8192)
    }

    @MainActor
    func testLMStudioAgentRoundSendsChosenThinkingLevel() async throws {
        let defaults = UserDefaults(suiteName: "parity-think-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        var connection = RemoteConnection.lmStudioPreset()
        connection.apiBaseURL = "http://127.0.0.1:1234/v1"
        connection.defaultModel = "qwen3.8-flash-next"
        connection.availableModels = ["qwen3.8-flash-next"]
        connection.liveModelCapabilities = [
            "qwen3.8-flash-next": LiveModelCapabilities(
                reasoningEfforts: [.low, .medium, .high],
                defaultReasoningEffort: .medium
            ),
        ]
        settings.updateConnection(connection)
        defer { ModelGenerationSettings.removeOptions(connectionID: connection.id) }
        // Qwen3.8's template takes only low, medium and xhigh, so pick one it accepts.
        ModelGenerationSettings.setOptions(
            ModelGenerationOptions(reasoningEffort: .low),
            connectionID: connection.id,
            modelID: "qwen3.8-flash-next"
        )
        ServiceWireStub.requests = []
        ServiceWireStub.reply = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\",\"reasoning_content\":\"think\"}}]}\n\ndata: [DONE]\n\n"
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "qwen3.8-flash-next")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        var thoughts = ""
        let result = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "hi")],
            tools: [tool],
            toolNames: ["lookup"],
            onReasoning: { thoughts += $0 }
        )
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(thoughts, "think")
        let sent = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertEqual(sent.body["reasoning_effort"] as? String, "low")
        XCTAssertEqual((sent.body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    @MainActor
    func testOdysseysServiceSendsResponsesWhenChosenOnACustomHost() async throws {
        let defaults = UserDefaults(suiteName: "parity-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        var connection = RemoteConnection(name: "Proxy", apiBaseURL: "https://llm.example.test/v1", apiKey: "k",
                                          defaultModel: "gpt-6-astra", availableModels: ["gpt-6-astra"])
        connection.openAIAPI = .responses
        settings.updateConnection(connection)
        defer { ModelGenerationSettings.removeOptions(connectionID: connection.id) }
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .high), connectionID: connection.id, modelID: "gpt-6-astra")
        ServiceWireStub.requests = []
        ServiceWireStub.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n"
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "gpt-6-astra")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        let result = try await service.agentRound(history: [LLMChatTurn(role: "user", content: "hi")], tools: [tool], toolNames: ["lookup"])
        XCTAssertEqual(result.text, "ok")
        let sent = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertEqual(sent.url, "https://llm.example.test/v1/responses")
        XCTAssertEqual((sent.body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNotNil(sent.body["input"])
        XCTAssertNil(sent.body["messages"])
        XCTAssertEqual((sent.body["tools"] as? [[String: Any]])?.first?["name"] as? String, "lookup")
    }

    @MainActor
    func testOdysseysServiceSendsChatCompletionsWhenChosenOnOpenAI() async throws {
        let defaults = UserDefaults(suiteName: "parity-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        var connection = RemoteConnection(name: "OpenAI", apiBaseURL: "https://api.openai.com/v1", apiKey: "k",
                                          defaultModel: "gpt-6-astra", availableModels: ["gpt-6-astra"])
        connection.openAIAPI = .chatCompletions
        settings.updateConnection(connection)
        defer { ModelGenerationSettings.removeOptions(connectionID: connection.id) }
        ModelGenerationSettings.setOptions(ModelGenerationOptions(reasoningEffort: .xhigh), connectionID: connection.id, modelID: "gpt-6-astra")
        ServiceWireStub.requests = []
        ServiceWireStub.reply = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "gpt-6-astra")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        _ = try await service.agentRound(history: [LLMChatTurn(role: "user", content: "hi")], tools: [tool], toolNames: ["lookup"])
        let sent = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertEqual(sent.url, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.body["reasoning_effort"] as? String, "xhigh")
        XCTAssertNotNil(sent.body["messages"])
        XCTAssertNil(sent.body["input"])
    }

    @MainActor
    func testResponsesSendsFunctionCallsFromHistoryWhenRememberThinkingIsOff() async throws {
        let defaults = UserDefaults(suiteName: "parity-resp-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        let connection = RemoteConnection(
            name: "OpenAI",
            apiBaseURL: "https://api.openai.com/v1",
            apiKey: "k",
            defaultModel: "gpt-6-astra",
            availableModels: ["gpt-6-astra"]
        )
        settings.updateConnection(connection)
        defer { ModelGenerationSettings.removeOptions(connectionID: connection.id) }
        ModelGenerationSettings.setOptions(
            ModelGenerationOptions(rememberThinking: false),
            connectionID: connection.id,
            modelID: "gpt-6-astra"
        )
        ServiceWireStub.requests = []
        ServiceWireStub.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r2\"}}\n\n"
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "gpt-6-astra")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        _ = try await service.agentRound(
            history: [
                LLMChatTurn(role: "user", content: "look this up"),
                LLMChatTurn(
                    role: "assistant",
                    content: "",
                    toolCalls: [EncodedFunctionCall(name: "lookup", arguments: #"{"q":"one"}"#, callID: "call_1")]
                ),
                LLMChatTurn(role: "tool", content: "one", toolCallID: "call_1"),
                LLMChatTurn(
                    role: "assistant",
                    content: "",
                    toolCalls: [EncodedFunctionCall(name: "lookup", arguments: #"{"q":"two"}"#, callID: "call_2")]
                ),
                LLMChatTurn(role: "tool", content: "two", toolCallID: "call_2"),
            ],
            tools: [tool],
            toolNames: ["lookup"]
        )
        let sent = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertTrue(sent.url.hasSuffix("/responses"), sent.url)
        XCTAssertEqual(sent.body["store"] as? Bool, false)
        XCTAssertNil(sent.body["previous_response_id"])
        XCTAssertEqual(sent.body["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(sent.body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, [
            "user", "function_call", "function_call_output", "function_call", "function_call_output",
        ])
        XCTAssertEqual(input[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["output"] as? String, "one")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_2")
        XCTAssertEqual(input[4]["output"] as? String, "two")
    }

    @MainActor
    func testAgentRoundDoesNotReuseAnotherConversationsResponseID() async throws {
        let defaults = UserDefaults(suiteName: "parity-id-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        let connection = RemoteConnection(
            name: "OpenAI",
            apiBaseURL: "https://api.openai.com/v1",
            apiKey: "k",
            defaultModel: "gpt-6-astra",
            availableModels: ["gpt-6-astra"]
        )
        settings.updateConnection(connection)
        defer { ModelGenerationSettings.removeOptions(connectionID: connection.id) }
        ModelGenerationSettings.setOptions(
            ModelGenerationOptions(rememberThinking: true),
            connectionID: connection.id,
            modelID: "gpt-6-astra"
        )
        ServiceWireStub.requests = []
        ServiceWireStub.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"one\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_chat_a\"}}\n\n"
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "gpt-6-astra")
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]]]
        let first = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "chat a")],
            tools: [tool],
            toolNames: ["lookup"]
        )
        XCTAssertEqual(first.responseID, "resp_chat_a")

        ServiceWireStub.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"two\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_chat_b\"}}\n\n"
        _ = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "chat b")],
            tools: [tool],
            toolNames: ["lookup"]
        )
        let second = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertNil(second.body["previous_response_id"], "a new conversation must not inherit the last Responses id")

        ServiceWireStub.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"cont\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_chat_a2\"}}\n\n"
        _ = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "continue a")],
            tools: [tool],
            toolNames: ["lookup"],
            previousResponseID: first.responseID
        )
        let continued = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertEqual(continued.body["previous_response_id"] as? String, "resp_chat_a")
    }
}

/// Coding models must call tools. Support comes from the provider's own capability info, then a
/// fallback table, and a one-time test call has to pass before a model can be picked.
final class ToolSupportTests: XCTestCase {
    func testFallbackTable() {
        for id in ["gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-4o", "gpt-4.1-mini", "o4-mini", "grok-4.7", "grok-4.5",
                   "gemini-3-pro", "claude-sonnet-5", "qwen3-coder-30b", "llama-3.3-70b", "gpt-oss-120b", "mistral-large", "deepseek-v3"] {
            XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: id), .supported, id)
        }
        for id in ["grok-imagine-image-2.0", "gpt-image-2", "dall-e-3", "text-embedding-3-large", "tts-1", "whisper-1",
                   "omni-moderation-latest", "gpt-4o-realtime-preview", "babbage-002", "o1-mini"] {
            XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: id), .unsupported, id)
        }
        XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: "my-finetune"), .unknown)
    }

    func testProviderCapabilityInfoWinsOverTheTable() throws {
        let openRouter = #"{"data":[{"id":"vendor/odd-model","supported_parameters":["tools","temperature"]},{"id":"gpt-4o","supported_parameters":["temperature"]}]}"#
        let lmStudio = #"{"data":[{"id":"qwen3-coder","capabilities":["tool_use"]},{"id":"tiny","capabilities":[]},{"id":"plain"}]}"#
        let a = try OpenAIRequestCodec.parseModelsList(Data(openRouter.utf8))
        XCTAssertEqual(a.map(\.supportsTools), [true, false])
        let b = try OpenAIRequestCodec.parseModelsList(Data(lmStudio.utf8))
        XCTAssertEqual(b.map(\.supportsTools), [true, nil, nil], "an empty capability list is no evidence either way")

        var c = RemoteConnection(name: "Router", apiBaseURL: "https://openrouter.ai/api/v1")
        c.replaceAvailableModels(with: a)
        XCTAssertEqual(c.modelToolSupport, ["vendor/odd-model": true, "gpt-4o": false])
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "vendor/odd-model", connection: c), .supported)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "gpt-4o", connection: c), .unsupported)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "grok-4.7", connection: c), .supported, "unlisted ids use the table")

        // The connection type is not the model: a qwen3 model on LM Studio still takes tools.
        let harmony = RemoteConnection.lmStudioPreset()
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "qwen3-coder", connection: harmony), .supported)
    }

    func testCodingAvailabilityNeedsAPassingTestCall() {
        let defaults = UserDefaults(suiteName: "tools-\(UUID().uuidString)")!
        let store = ToolCallVerificationStore(defaults: defaults)
        let usable: Set<RemoteProtocolEncoding> = [.openAIChatCompletions, .geminiOpenAI]
        let xai = RemoteConnection(id: "x", name: "xAI", apiBaseURL: "https://api.x.ai/v1", availableModels: ["grok-4.7", "grok-imagine-image-2.0"])
        let grok = ConfiguredModelChoice(id: "grok-4.7", displayName: "Grok 4.7", backend: .remote, providerLabel: "xAI", connectionID: "x")
        let image = ConfiguredModelChoice(id: "grok-imagine-image-2.0", displayName: "Grok Imagine", backend: .remote, providerLabel: "xAI", connectionID: "x")
        let apple = ConfiguredModelChoice(id: ModelCapabilityCatalog.appleFoundationModelID, displayName: "Apple On-Device", backend: .appleFoundation, providerLabel: "Apple", connectionID: nil)

        XCTAssertEqual(ToolModelPolicy.availability(of: grok, connection: xai, store: store, usableEncodings: usable), .needsTest)
        store.record(passed: true, for: grok.selectionKey)
        XCTAssertEqual(ToolModelPolicy.availability(of: grok, connection: xai, store: store, usableEncodings: usable), .ready)
        XCTAssertEqual(ToolModelPolicy.availability(of: image, connection: xai, store: store, usableEncodings: usable),
                       .unavailable(ToolModelPolicy.noToolsReason))
        store.record(passed: false, for: grok.selectionKey)
        XCTAssertEqual(ToolModelPolicy.availability(of: grok, connection: xai, store: store, usableEncodings: usable),
                       .failedTest)
        XCTAssertEqual(ToolModelPolicy.availability(of: apple, connection: nil, store: store, usableEncodings: usable), .ready)

        var anthropic = RemoteConnection.anthropicPreset()
        anthropic.id = "a"
        let claude = ConfiguredModelChoice(id: "claude-sonnet-5", displayName: "Claude", backend: .remote, providerLabel: "Claude", connectionID: "a")
        XCTAssertEqual(ToolModelPolicy.availability(of: claude, connection: anthropic, store: store, usableEncodings: usable),
                       .unavailable(ToolModelPolicy.protocolReason), "a connection type the app can't drive isn't a model without tools")

        // A changed model list or a removed result clears the old verdict.
        store.clear(connectionID: "x")
        XCTAssertEqual(ToolModelPolicy.availability(of: grok, connection: xai, store: store, usableEncodings: usable), .needsTest)
    }

    func testChoicesAreGroupedByConnection() {
        let choices = [
            ConfiguredModelChoice(id: "apple_foundation", displayName: "Apple On-Device", backend: .appleFoundation, providerLabel: "Apple", connectionID: nil),
            ConfiguredModelChoice(id: "grok-4.7", displayName: "Grok 4.7", backend: .remote, providerLabel: "xAI", connectionID: "x"),
            ConfiguredModelChoice(id: "gpt-6-astra", displayName: "GPT-6 Astra", backend: .remote, providerLabel: "OpenAI", connectionID: "o"),
            ConfiguredModelChoice(id: "grok-4.6", displayName: "Grok 4.6", backend: .remote, providerLabel: "xAI", connectionID: "x"),
        ]
        let groups = ToolModelPolicy.grouped(choices)
        XCTAssertEqual(groups.map(\.title), ["xAI", "OpenAI", "On This Device"])
        XCTAssertEqual(groups[0].choices.map(\.id), ["grok-4.7", "grok-4.6"])
        XCTAssertEqual(groups[2].choices.map(\.id), ["apple_foundation"])
    }
}
