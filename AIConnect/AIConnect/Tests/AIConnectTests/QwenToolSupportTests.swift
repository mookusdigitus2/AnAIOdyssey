// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// Answers GET requests from a path -> JSON table and records which URLs were asked for.
final class ModelsListStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    /// Every request times out, like a server that is switched off.
    nonisolated(unsafe) static var unreachable = false
    /// Status codes by path (an error body is sent with them).
    nonisolated(unsafe) static var statuses: [String: Int] = [:]
    /// Seconds before each answer, like a slow or far-away server.
    nonisolated(unsafe) static var delay: TimeInterval = 0
    static func reset() { bodies = [:]; asked = []; unreachable = false; statuses = [:]; delay = 0 }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ModelsListStub.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.asked.append(url.absoluteString)
        let unreachable = Self.unreachable, status = Self.statuses[url.path], body = Self.bodies[url.path]
        let answer: @Sendable () -> Void = { [self] in
            if unreachable {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            let code = status ?? (body == nil ? 404 : 200)
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let text = status == nil ? (body ?? #"{"error":"not found"}"#) : #"{"error":"status \#(code)"}"#
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: answer)
        } else {
            answer()
        }
    }
    override func stopLoading() {}
}

/// User report: "when I run the coding app and select qwen3.8-flash-next for the model it says doesn't support
/// tools. it does though." The LM Studio connection type was being reported as the model's
/// limit, and a model with no capability info has to read "Untested", not "Doesn't support tools".
final class QwenToolSupportTests: XCTestCase {
    private let qwen = "qwen3.8-flash-next"
    private let toolCapableEncodings: Set<RemoteProtocolEncoding> = [.automatic, .openAIChatCompletions, .geminiOpenAI, .lmStudioHarmony]

    private func choice(_ id: String, on c: RemoteConnection) -> ConfiguredModelChoice {
        ConfiguredModelChoice(id: id, displayName: id, backend: .remote, providerLabel: c.trimmedName, connectionID: c.id)
    }

    private func freshStore() -> ToolCallVerificationStore {
        ToolCallVerificationStore(defaults: UserDefaults(suiteName: "qwen-\(UUID().uuidString)")!)
    }

    func testQwen38FlashNextOnLMStudioIsNotMarkedWithoutTools() {
        var lm = RemoteConnection.lmStudioPreset()
        lm.availableModels = [qwen]
        XCTAssertEqual(lm.encoding, .automatic)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: lm), .supported)
        let state = ToolModelPolicy.availability(of: choice(qwen, on: lm), connection: lm, store: freshStore(),
                                                 usableEncodings: toolCapableEncodings)
        XCTAssertEqual(state, .needsTest, "picked once, then the one-time tool test decides")
        XCTAssertNotEqual(state, .unavailable(ToolModelPolicy.noToolsReason))
    }

    func testAnAppThatCantDriveTheConnectionSaysSoInsteadOfBlamingTheModel() {
        let lm = RemoteConnection.lmStudioPreset()
        let state = ToolModelPolicy.availability(of: choice(qwen, on: lm), connection: lm, store: freshStore(),
                                                 usableEncodings: [.openAIChatCompletions])
        XCTAssertEqual(state, .unavailable(ToolModelPolicy.protocolReason))
    }

    func testQwen38FlashNextOnOtherConnectionTypes() {
        let store = freshStore()
        for c in [RemoteConnection(name: "Router", apiBaseURL: "https://openrouter.ai/api/v1"),
                  RemoteConnection(name: "LM on Mac", apiBaseURL: "http://192.168.1.100:1234/v1")] {
            for id in [qwen, "qwen/\(qwen)", "lmstudio-community/Qwen3.8-Flash-Next-GGUF", "mlx-community/Qwen3.8-Flash-Next-4bit"] {
                XCTAssertEqual(ModelToolSupportCatalog.support(modelID: id, connection: c), .supported, "\(c.trimmedName) \(id)")
                XCTAssertEqual(ToolModelPolicy.availability(of: choice(id, on: c), connection: c, store: store,
                                                            usableEncodings: toolCapableEncodings), .needsTest, id)
            }
        }
    }

    func testQwenFamiliesMatchByVersionNotExactName() {
        for id in ["qwen2.5-coder-32b-instruct", "qwen2.5-7b", "qwen3", "qwen3-coder-next", "qwen3.6-flash", qwen,
                   "qwen3.8-max-prime", "qwen4-preview", "qwen10-mini", "Qwen3.8-Flash-Next@q4_k_m", "qwq-32b"] {
            XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: id), .supported, id)
        }
        for id in ["qwen2-7b-instruct", "qwen1.5-14b", "qwen-7b"] {
            XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: id), .unknown, "older qwen is untested, not refused: \(id)")
        }
        XCTAssertEqual(ModelToolSupportCatalog.fallback(modelID: "qwen3-embedding-8b"), .unsupported, "embeddings never chat")
    }

    func testModelsWithNoInfoReadUntestedNotWithoutTools() {
        let c = RemoteConnection(id: "m", name: "Mine", apiBaseURL: "http://localhost:8080/v1", availableModels: ["house-model-v2"])
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "house-model-v2", connection: c), .unknown)
        XCTAssertEqual(ToolModelPolicy.availability(of: choice("house-model-v2", on: c), connection: c, store: freshStore(),
                                                    usableEncodings: toolCapableEncodings), .needsTest)
        XCTAssertEqual(ToolModelPolicy.untestedLabel, "Untested")
    }

    func testOnlyExplicitEvidenceMarksAModelWithoutTools() throws {
        // OpenRouter's supported_parameters is a full list, so a missing "tools" is explicit.
        let router = #"{"data":[{"id":"qwen/qwen3.8-flash","supported_parameters":["tools","tool_choice"]},{"id":"old/model","supported_parameters":["temperature"]}]}"#
        XCTAssertEqual(try OpenAIRequestCodec.parseModelsList(Data(router.utf8)).map(\.supportsTools), [true, false])
        // LM Studio /api/v0/models lists "tool_use" for native models. An empty list on an
        // llm/vlm is default tool use, which the tool-use spec still supports.
        let v0 = #"{"object":"list","data":[{"id":"qwen3.8-flash-next","type":"llm","capabilities":["tool_use"]},{"id":"gemma-4","type":"vlm","capabilities":[]}]}"#
        XCTAssertEqual(try OpenAIRequestCodec.parseModelsList(Data(v0.utf8)).map(\.supportsTools), [true, true])
        let v1 = #"{"models":[{"key":"qwen3.8-flash-next","type":"llm","capabilities":{"vision":false,"trained_for_tool_use":true}},{"key":"phi-5","type":"llm","capabilities":{"vision":false,"trained_for_tool_use":false}}]}"#
        let parsed = try OpenAIRequestCodec.parseModelsList(Data(v1.utf8))
        XCTAssertEqual(parsed.map(\.id), ["qwen3.8-flash-next", "phi-5"])
        XCTAssertEqual(parsed.map(\.supportsTools), [true, true], "trained_for_tool_use false is default tool use, not a refusal")
        XCTAssertEqual(OpenAIRequestCodec.toolSupport(in: ["capabilities": ["function_calling": false]]), false)
    }

    @MainActor
    func testLMStudioModelRefreshReadsItsNativeCapabilityList() async throws {
        let defaults = UserDefaults(suiteName: "lm-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
        var lm = RemoteConnection.lmStudioPreset()
        lm.apiBaseURL = "http://127.0.0.1:1234/v1"
        settings.updateConnection(lm)
        ModelsListStub.asked = []
        ModelsListStub.bodies = [
            "/v1/models": #"{"object":"list","data":[{"id":"qwen3.8-flash-next","object":"model","owned_by":"organization_owner"},{"id":"text-embedding-nomic-embed-text-v2","object":"model"}]}"#,
            "/api/v0/models": #"{"object":"list","data":[{"id":"qwen3.8-flash-next","type":"llm","capabilities":["tool_use"]},{"id":"text-embedding-nomic-embed-text-v2","type":"embeddings"}]}"#,
        ]
        let service = RemoteLLMService(settings: settings, session: ModelsListStub.session)
        let models = try await service.queryModels(for: lm.id)
        XCTAssertEqual(models.map(\.id), ["qwen3.8-flash-next", "text-embedding-nomic-embed-text-v2"])
        XCTAssertTrue(ModelsListStub.asked.contains("http://127.0.0.1:1234/api/v1/models"), "\(ModelsListStub.asked)")
        XCTAssertTrue(ModelsListStub.asked.contains("http://127.0.0.1:1234/api/v0/models"), "\(ModelsListStub.asked)")
        let saved = try XCTUnwrap(settings.connection(id: lm.id))
        XCTAssertEqual(saved.modelToolSupport, [
            "qwen3.8-flash-next": true,
            "text-embedding-nomic-embed-text-v2": false,
        ])

        // Without LM Studio's native list (older server, or another app on :1234) the refresh still works.
        ModelsListStub.bodies.removeValue(forKey: "/api/v0/models")
        _ = try await service.queryModels(for: lm.id)
        XCTAssertNil(settings.connection(id: lm.id)?.modelToolSupport)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: settings.connection(id: lm.id)), .supported)
    }

    @MainActor
    func testOtherProvidersAreNotAskedForLMStudiosList() async throws {
        let defaults = UserDefaults(suiteName: "router-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
        var router = RemoteConnection(name: "Router", apiBaseURL: "https://router.test/api/v1")
        router.apiKey = "sk-test"
        settings.updateConnection(router)
        ModelsListStub.asked = []
        ModelsListStub.bodies = ["/api/v1/models": #"{"data":[{"id":"qwen/qwen3.8-flash","supported_parameters":["tools"]}]}"#]
        _ = try await RemoteLLMService(settings: settings, session: ModelsListStub.session).queryModels(for: router.id)
        XCTAssertEqual(ModelsListStub.asked, ["https://router.test/api/v1/models"])
    }

    func testAFailedToolTestCanBeRunAgain() {
        let store = freshStore()
        var lm = RemoteConnection.lmStudioPreset()
        lm.availableModels = [qwen]
        let pick = choice(qwen, on: lm)
        store.record(passed: false, for: pick.selectionKey)
        let failed = ToolModelPolicy.availability(of: pick, connection: lm, store: store, usableEncodings: toolCapableEncodings)
        XCTAssertEqual(failed, .failedTest)
        XCTAssertTrue(failed.isSelectable, "picking it again re-runs the test")
        XCTAssertTrue(failed.runsTestWhenPicked)
        XCTAssertFalse(ToolModelAvailability.ready.runsTestWhenPicked)
        store.record(passed: true, for: pick.selectionKey)
        XCTAssertEqual(ToolModelPolicy.availability(of: pick, connection: lm, store: store, usableEncodings: toolCapableEncodings), .ready)
    }

    /// GET /api/v1/models example from https://lmstudio.ai/docs/developer/rest/list
    /// plus a qwen3.8 row whose `trained_for_tool_use` is false.
    func testV1ListFixtureKeepsQwenAndDeepSeekCapable() throws {
        let parsed = try OpenAIRequestCodec.parseModelsList(Data(LMStudioSpecFixtures.v1Models.utf8))
        XCTAssertEqual(parsed.map(\.id), [
            "google/gemma-4-26b-a4b",
            "deepseek-r1",
            "text-embedding-nomic-embed-text-v1.5-embedding",
            "qwen3.8-flash-next",
        ])
        XCTAssertEqual(parsed.map(\.supportsTools), [true, true, false, true])
        XCTAssertEqual(parsed.map(\.contextWindowTokens), [8192, 163_840, nil, 131_072])
        XCTAssertEqual(parsed.map(\.supportsVision), [true, false, nil, false])
        XCTAssertEqual(parsed.first?.reasoningEfforts, [.low, .medium])

        var lm = RemoteConnection.lmStudioPreset()
        lm.replaceAvailableModels(with: parsed)
        let expanded = LMStudioNativeModels.includingAliases(parsed, json: Data(LMStudioSpecFixtures.v1Models.utf8))
        XCTAssertEqual(
            expanded.first { $0.id == "google/gemma-4-26b-a4b@q4_k_m" }?.supportsTools,
            true,
            "a loaded variant id is the same model as key"
        )
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: "deepseek-r1", connection: lm), .supported)
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: lm), .supported)
        XCTAssertEqual(
            ModelToolSupportCatalog.support(modelID: "text-embedding-nomic-embed-text-v1.5-embedding", connection: lm),
            .unsupported
        )
        XCTAssertEqual(
            ModelToolSupportCatalog.fallback(modelID: "deepseek-r1"),
            .unsupported,
            "the name table still refuses deepseek-r1 off LM Studio"
        )

        var stale = RemoteConnection.lmStudioPreset()
        stale.availableModels = [qwen, "deepseek-r1"]
        stale.modelToolSupport = [qwen: false, "deepseek-r1": false]
        for id in [qwen, "deepseek-r1"] {
            XCTAssertEqual(ModelToolSupportCatalog.support(modelID: id, connection: stale), .supported, id)
            let state = ToolModelPolicy.availability(of: choice(id, on: stale), connection: stale, store: freshStore(),
                                                     usableEncodings: toolCapableEncodings)
            XCTAssertEqual(state, .needsTest, id)
            XCTAssertNotEqual(state, .unavailable(ToolModelPolicy.noToolsReason), id)
        }
    }

    func testLMStudioChatCompletionsSendTheToolsArray() {
        let adapter = RemoteProtocolAdapterRegistry.adapter(for: .lmStudioHarmony)
        XCTAssertTrue(adapter.supportsStructuredTools)
        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "search_products",
                "description": "Search the product catalog",
                "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]],
            ],
        ]
        let body = adapter.chatPayload(
            model: "lmstudio-community/qwen2.5-7b-instruct",
            messages: [["role": "user", "content": "What dell products do you have under $50 in electronics?"]],
            stream: false,
            tools: [tool]
        )
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertEqual(body["model"] as? String, "lmstudio-community/qwen2.5-7b-instruct")
    }

    func testDefaultAndQwenToolTextBecomesAToolCall() {
        let adapter = RemoteProtocolAdapterRegistry.adapter(for: .lmStudioHarmony)
        let qwen = """
        <tool_call>
        {"name": "get_delivery_date", "arguments": {"order_id": "123"}}
        </tool_call>
        """
        let blocks = adapter.parseToolBlocks(from: qwen, tags: ["get_delivery_date"])
        XCTAssertEqual(blocks.map(\.toolType), ["get_delivery_date"])
        XCTAssertEqual(blocks.first?.content, "{\"order_id\":\"123\"}")
        XCTAssertEqual(adapter.stripToolBlocks(from: qwen, tags: ["get_delivery_date"]), "")

        let fallback = #"[TOOL_REQUEST]{"name": "report_ready", "arguments": {"ok": true}}[END_TOOL_REQUEST]"#
        let ready = adapter.parseToolBlocks(from: fallback, tags: ["report_ready"])
        XCTAssertEqual(ready.map(\.toolType), ["report_ready"])
    }

    @MainActor
    func testV1ListAloneMarksUntunedQwenCapable() async throws {
        let defaults = UserDefaults(suiteName: "lm-v1-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: RemoteAPIKeyStore(secureStore: MemorySecureStore()))
        var lm = RemoteConnection.lmStudioPreset()
        lm.apiBaseURL = "http://127.0.0.1:1234/v1"
        settings.updateConnection(lm)
        ModelsListStub.asked = []
        ModelsListStub.bodies = [
            "/v1/models": #"{"object":"list","data":[{"id":"qwen3.8-flash-next","object":"model","owned_by":"organization_owner"},{"id":"google/gemma-4-26b-a4b@q4_k_m","object":"model"}]}"#,
            "/api/v1/models": LMStudioSpecFixtures.v1Models,
        ]
        let models = try await RemoteLLMService(settings: settings, session: ModelsListStub.session).queryModels(for: lm.id)
        XCTAssertEqual(models.map(\.id), ["qwen3.8-flash-next", "google/gemma-4-26b-a4b@q4_k_m"])
        let saved = try XCTUnwrap(settings.connection(id: lm.id))
        XCTAssertEqual(saved.modelToolSupport?["qwen3.8-flash-next"], true)
        XCTAssertEqual(saved.modelToolSupport?["google/gemma-4-26b-a4b@q4_k_m"], true)
        XCTAssertEqual(saved.modelToolSupport?["text-embedding-nomic-embed-text-v1.5-embedding"], nil,
                       "the embedding is not on the OpenAI id list, so it is not a chat choice")
        XCTAssertEqual(ModelToolSupportCatalog.support(modelID: qwen, connection: saved), .supported)
        XCTAssertEqual(saved.liveCapabilities(for: "google/gemma-4-26b-a4b@q4_k_m")?.contextWindowTokens, 8192)
        XCTAssertEqual(saved.liveCapabilities(for: qwen)?.contextWindowTokens, 131_072)
        XCTAssertEqual(saved.liveCapabilities(for: "google/gemma-4-26b-a4b@q4_k_m")?.supportsVision, true)
    }
}

enum LMStudioSpecFixtures {
    /// Documented `GET /api/v1/models` body, plus qwen3.8 with `trained_for_tool_use: false`.
    static let v1Models = """
    {"models":[
      {"type":"llm","publisher":"google","key":"google/gemma-4-26b-a4b","display_name":"Gemma 4 26B A4B",
       "max_context_length":32768,
       "loaded_instances":[{"id":"google/gemma-4-26b-a4b","config":{"context_length":8192}}],
       "capabilities":{"vision":true,"trained_for_tool_use":true,
         "reasoning":{"allowed_options":["low","medium"],"default":"medium"}},
       "variants":["google/gemma-4-26b-a4b@q4_k_m"],"selected_variant":"google/gemma-4-26b-a4b@q4_k_m"},
      {"type":"llm","publisher":"deepseek","key":"deepseek-r1","display_name":"DeepSeek R1",
       "max_context_length":163840,
       "capabilities":{"vision":false,"trained_for_tool_use":true}},
      {"type":"embedding","publisher":"gaianet","key":"text-embedding-nomic-embed-text-v1.5-embedding",
       "display_name":"Nomic Embed Text v1.5"},
      {"type":"llm","publisher":"qwen","key":"qwen3.8-flash-next","display_name":"Qwen 3.8 Flash Next",
       "max_context_length":131072,
       "capabilities":{"vision":false,"trained_for_tool_use":false}}
    ]}
    """
}
