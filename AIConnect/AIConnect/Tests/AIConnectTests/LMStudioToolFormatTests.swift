// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// #209: LM Studio defaulted every model to Harmony. Automatic picks Harmony
/// only for GPT-OSS; Qwen and the rest use standard OpenAI tools.
/// #204: Chat Completions dropped `tool_calls` / `tool_call_id`.
/// #198: Harmony mode must still send native `tools` (locked after #210).
final class LMStudioToolFormatTests: XCTestCase {
    func testLMStudioPresetDefaultsToAutomatic() {
        let lm = RemoteConnection.lmStudioPreset()
        XCTAssertEqual(lm.encoding, .automatic)
        XCTAssertEqual(lm.resolvedEncoding(forModel: "qwen3.8-27b"), .openAIChatCompletions)
        XCTAssertEqual(lm.resolvedEncoding(forModel: "qwen3.8-flash-next"), .openAIChatCompletions)
        XCTAssertEqual(lm.resolvedEncoding(forModel: "gpt-oss-120b"), .lmStudioHarmony)
        XCTAssertEqual(lm.resolvedEncoding(forModel: "openai/gpt-oss-20b"), .lmStudioHarmony)
        XCTAssertEqual(lm.resolvedEncoding(forModel: ""), .openAIChatCompletions)
    }

    func testToolFormatLabels() {
        XCTAssertEqual(RemoteProtocolEncoding.automatic.displayName, ToolFormatLabels.automatic)
        XCTAssertEqual(RemoteProtocolEncoding.openAIChatCompletions.displayName, ToolFormatLabels.standard)
        XCTAssertEqual(RemoteProtocolEncoding.lmStudioHarmony.displayName, ToolFormatLabels.gptOSS)
        XCTAssertEqual(ToolFormatLabels.automatic, "Automatic")
        XCTAssertEqual(ToolFormatLabels.standard, "Standard (OpenAI)")
        XCTAssertEqual(ToolFormatLabels.gptOSS, "GPT-OSS (Harmony)")
        XCTAssertEqual(RemoteProtocolEncoding.geminiOpenAI.displayName, "Gemini (OpenAI-compatible)")
        XCTAssertEqual(RemoteProtocolEncoding.ollamaNative.displayName, "Ollama")
        XCTAssertEqual(RemoteProtocolEncoding.anthropicMessages.displayName, "Anthropic Messages (Claude)")
        XCTAssertEqual(RemoteProtocolEncoding.allCases.first, .automatic)
    }

    func testToolFormatPickerHidesConnectionTypes() {
        XCTAssertEqual(
            RemoteProtocolEncoding.toolFormatPickerCases,
            [.automatic, .openAIChatCompletions, .lmStudioHarmony]
        )
        XCTAssertTrue(RemoteConnection.lmStudioPreset().showsToolFormatPicker)
        XCTAssertTrue(RemoteConnection.openAIPreset().showsToolFormatPicker)
        XCTAssertTrue(RemoteConnection.xAIPreset().showsToolFormatPicker)
        XCTAssertFalse(RemoteConnection.geminiPreset().showsToolFormatPicker)
        XCTAssertFalse(RemoteConnection.anthropicPreset().showsToolFormatPicker)
        let ollama = RemoteConnection(name: "Ollama", apiBaseURL: "http://localhost:11434", encoding: .ollamaNative)
        XCTAssertFalse(ollama.showsToolFormatPicker)
        XCTAssertFalse(RemoteProtocolEncoding.geminiOpenAI.offersToolFormatPicker)
        XCTAssertFalse(RemoteProtocolEncoding.ollamaNative.offersToolFormatPicker)
        XCTAssertFalse(RemoteProtocolEncoding.anthropicMessages.offersToolFormatPicker)
    }

    func testAutomaticResolutionCaptionNamesPickedFormatAndModel() {
        var lm = RemoteConnection.lmStudioPreset()
        lm.defaultModel = "qwen3.8-27b"
        XCTAssertEqual(
            lm.automaticResolutionCaption(),
            "Using \(ToolFormatLabels.standard) for qwen3.8-27b."
        )
        XCTAssertEqual(
            lm.automaticResolutionCaption(forModel: "openai/gpt-oss-20b"),
            "Using \(ToolFormatLabels.gptOSS) for openai/gpt-oss-20b."
        )
        lm.defaultModel = ""
        XCTAssertEqual(lm.automaticResolutionCaption(), "Using \(ToolFormatLabels.standard).")
        lm.encoding = .openAIChatCompletions
        XCTAssertNil(lm.automaticResolutionCaption(forModel: "qwen3.8-27b"))
    }

    func testStandardAdapterDoesNotRunHarmonyCleanupOnPlainText() {
        let adapter = OpenAIChatCompletionsAdapter()
        XCTAssertEqual(adapter.sanitizeAssistantText("3D printing and 4K video"), "3D printing and 4K video")
        XCTAssertEqual(
            adapter.sanitizeAssistantText("Here is the answer. Here is the answer. Here is the answer. Here is the answer."),
            "Here is the answer. Here is the answer. Here is the answer. Here is the answer."
        )
        XCTAssertTrue(adapter.parseToolBlocks(from: "3D printing to=nowhere", tags: ["lookup"]).isEmpty)
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText("3D printing and 4K video"), "3D printing and 4K video")
    }

    func testHarmonyCleanupLeavesOrdinaryProseAndURLsAlone() {
        XCTAssertFalse(HarmonyResponseCodec.containsHarmonyTokens("https://example.com/?to=assistant&x=1"))
        XCTAssertEqual(
            HarmonyResponseCodec.sanitizeAssistantText("See https://example.com/?to=assistant and a 3D printer."),
            "See https://example.com/?to=assistant and a 3D printer."
        )
        XCTAssertTrue(HarmonyResponseCodec.parseHarmonyToolCalls(from: "https://example.com/?to=lookup", tags: ["lookup"]).isEmpty)
        let framed = "<|channel|>final<|message|>Buy a 3D printer and 4K display.<|return|>"
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText(framed), "Buy a 3D printer and 4K display.")
    }

    func testHarmonyCleanupKeepsTextAfterARepeatedParagraph() {
        let paragraph = String(repeating: "This paragraph is long enough to look like a decode leak. ", count: 3)
        let unique = "Then the model continues with a second thought that must stay."
        let body = paragraph + paragraph + unique
        let framed = "<|channel|>final<|message|>\(body)<|return|>"
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText(framed), body)
        let exact = paragraph + paragraph
        XCTAssertEqual(
            HarmonyResponseCodec.sanitizeAssistantText("<|channel|>final<|message|>\(exact)<|return|>"),
            paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testChatHistoryKeepsEveryToolRound() {
        let first = LLMChatToolHistory.assigningCallIDs([
            ToolCallBlock(toolType: "lookup", content: #"{"q":"one"}"#, callID: "call_1"),
        ])
        var history = [
            LLMChatTurn(role: "user", content: "do it"),
            LLMChatToolHistory.assistantTurn(text: "", blocks: first),
        ]
        history.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: [
            EncodedFunctionCallOutput(callID: "call_1", output: "one"),
        ]))
        let second = LLMChatToolHistory.assigningCallIDs([
            ToolCallBlock(toolType: "lookup", content: #"{"q":"two"}"#, callID: "call_2"),
        ])
        history.append(LLMChatToolHistory.assistantTurn(text: "", blocks: second))
        history.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: [
            EncodedFunctionCallOutput(callID: "call_2", output: "two"),
        ]))
        let messages = ChatCompletionToolRoundTrip.applying(
            to: history.map(\.chatMessage),
            functionCalls: [],
            functionCallOutputs: []
        )
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "tool", "assistant", "tool"])
        XCTAssertEqual(messages[1].toolCalls.map(\.id), ["call_1"])
        XCTAssertEqual(messages[2].toolCallID, "call_1")
        XCTAssertEqual(messages[3].toolCalls.map(\.id), ["call_2"])
        XCTAssertEqual(messages[4].toolCallID, "call_2")
    }

    func testFallbackMessageNamesModel() {
        XCTAssertEqual(
            ToolFormatFallbackCopy.message(model: "qwen3.8-27b"),
            "qwen3.8-27b answered without using its tools. Try a different Tool Format in this connection's Advanced settings."
        )
        XCTAssertEqual(
            ToolFormatFallbackCopy.message(model: "  "),
            "This model answered without using its tools. Try a different Tool Format in this connection's Advanced settings."
        )
        XCTAssertEqual(ToolFormatFallbackCopy.changeButtonTitle, "Change Tool Format")
    }

    func testMigrateNonGPTOSSHarmonyConnectionsToAutomatic() {
        var qwen = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: RemoteConnection.defaultLMStudioBaseURL,
            defaultModel: "qwen3.8-27b",
            encoding: .lmStudioHarmony
        )
        var empty = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: RemoteConnection.defaultLMStudioBaseURL,
            encoding: .lmStudioHarmony
        )
        var oss = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: RemoteConnection.defaultLMStudioBaseURL,
            defaultModel: "gpt-oss-120b",
            encoding: .lmStudioHarmony
        )
        let openai = RemoteConnection.openAIPreset()
        let migrated = RemoteConnection.migrateToolFormat([qwen, empty, oss, openai])
        XCTAssertEqual(migrated[0].encoding, .automatic)
        XCTAssertEqual(migrated[1].encoding, .automatic)
        XCTAssertEqual(migrated[2].encoding, .lmStudioHarmony, "explicit Harmony on GPT-OSS stays")
        XCTAssertEqual(migrated[3].encoding, .openAIChatCompletions)
        qwen.migrateOffStaleHarmony()
        empty.migrateOffStaleHarmony()
        oss.migrateOffStaleHarmony()
        XCTAssertEqual(qwen.encoding, .automatic)
        XCTAssertEqual(empty.encoding, .automatic)
        XCTAssertEqual(oss.encoding, .lmStudioHarmony)
    }

    @MainActor
    func testProviderSettingsMigratesSavedHarmonyQwenRows() {
        let defaults = UserDefaults(suiteName: "tool-format-\(UUID().uuidString)")!
        let store = RemoteAPIKeyStore(secureStore: MemorySecureStore())
        let stale = RemoteConnection(
            id: "stale-lm",
            name: "LM Studio",
            apiBaseURL: RemoteConnection.defaultLMStudioBaseURL,
            defaultModel: "qwen3.8-27b",
            encoding: .lmStudioHarmony
        )
        defaults.set(try! JSONEncoder().encode([stale]), forKey: "anaiodyssey.remote.connections")
        let settings = ProviderSettings(defaults: defaults, apiKeyStore: store)
        XCTAssertEqual(settings.connection(id: "stale-lm")?.encoding, .automatic)
    }

    func testAutomaticAndHarmonyAdaptersSendNativeTools() {
        for encoding in [RemoteProtocolEncoding.automatic, .lmStudioHarmony, .openAIChatCompletions] {
            let adapter = RemoteProtocolAdapterRegistry.adapter(for: encoding)
            XCTAssertTrue(adapter.supportsStructuredTools, "\(encoding)")
            let body = adapter.chatPayload(
                model: "qwen3.8-27b",
                messages: [["role": "user", "content": "hi"]],
                stream: false,
                tools: [[
                    "type": "function",
                    "function": ["name": "lookup", "description": "d", "parameters": ["type": "object"]],
                ]]
            )
            XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1, "\(encoding)")
            XCTAssertEqual(body["tool_choice"] as? String, "auto", "\(encoding)")
        }
        XCTAssertFalse(RemoteProtocolAdapterRegistry.adapter(for: .anthropicMessages).supportsStructuredTools)
    }

    func testResolvedAdapterForQwenIsOpenAINotHarmony() {
        var lm = RemoteConnection.lmStudioPreset()
        lm.defaultModel = "qwen3.8-27b"
        let adapter = RemoteProtocolAdapterRegistry.adapter(for: lm.resolvedEncoding(forModel: lm.trimmedModel))
        XCTAssertEqual(adapter.encoding, .openAIChatCompletions)
        XCTAssertTrue(adapter.supportsStructuredTools)
    }

    func testChatCompletionsIDFillsToolCallBlock() {
        let block = ToolCallParsing.toolBlock(from: [
            "id": "call_abc",
            "type": "function",
            "function": ["name": "lookup", "arguments": #"{"query":"hi"}"#],
        ])
        XCTAssertEqual(block?.callID, "call_abc")
        XCTAssertEqual(block?.toolType, "lookup")
    }

    func testAccumulatorKeepsParallelCallIDs() {
        var accumulator = OpenAICompatibleAPI.StructuredToolCallAccumulator()
        accumulator.append(json: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"read_file","arguments":""}}]}}]}"#)
        accumulator.append(json: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"list_files","arguments":""}}]}}]}"#)
        accumulator.append(json: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"a.swift\"}"}}]}}]}"#)
        accumulator.append(json: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]}}]}"#)
        let blocks = accumulator.finish()
        XCTAssertEqual(blocks.map(\.callID), ["call_a", "call_b"])
        XCTAssertEqual(blocks.map(\.toolType), ["read_file", "list_files"])
        let encoded = accumulator.encodedCalls()
        XCTAssertEqual(encoded.map(\.callID), ["call_a", "call_b"])
        XCTAssertEqual(encoded.first?.arguments, #"{"path":"a.swift"}"#)
    }

    func testChatPayloadCarriesAssistantToolCallsAndToolResults() {
        let messages = ChatCompletionToolRoundTrip.applying(
            to: [
                ChatCompletionMessage(role: "system", content: "sys"),
                ChatCompletionMessage(role: "user", content: "edit it"),
            ],
            functionCalls: [
                EncodedFunctionCall(name: "read_file", arguments: #"{"path":"a.swift"}"#, callID: "call_1"),
                EncodedFunctionCall(name: "list_files", arguments: "{}", callID: "call_2"),
            ],
            functionCallOutputs: [
                EncodedFunctionCallOutput(callID: "call_1", output: "let x = 1"),
                EncodedFunctionCallOutput(callID: "call_2", output: "a.swift"),
            ]
        )
        let body = OpenAICompatibleAPI.chatPayload(
            model: "qwen3.8-27b",
            typedMessages: messages,
            stream: false,
            tools: [[
                "type": "function",
                "function": ["name": "read_file", "description": "d", "parameters": ["type": "object"]],
            ]]
        )
        let sent = try! XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent[2]["role"] as? String, "assistant")
        let calls = try! XCTUnwrap(sent[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["id"] as? String, "call_1")
        XCTAssertEqual(calls[1]["id"] as? String, "call_2")
        XCTAssertEqual((calls[0]["function"] as? [String: Any])?["name"] as? String, "read_file")
        XCTAssertEqual(sent[3]["role"] as? String, "tool")
        XCTAssertEqual(sent[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(sent[4]["role"] as? String, "tool")
        XCTAssertEqual(sent[4]["tool_call_id"] as? String, "call_2")
        XCTAssertNotNil(body["tools"])
    }

    func testFallbackPolicyCatchesHarmonyOnQwenAndFailedToolText() {
        XCTAssertTrue(ToolFormatFallbackPolicy.looksLikeGPTOSS("openai/gpt-oss-120b"))
        XCTAssertFalse(ToolFormatFallbackPolicy.looksLikeGPTOSS("qwen3.8-27b"))
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "Sure, I'll edit the file.",
                forcedHarmonyOnNonGPTOSS: true
            )
        )
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "<|channel|>commentary to=functions.read_file <|message|>{}",
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: #"<tool_call>["name": broken]</tool_call>"#,
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertFalse(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "The function adds two numbers.",
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertFalse(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 1,
                assistantText: "unused",
                forcedHarmonyOnNonGPTOSS: true
            )
        )
    }

    func testAutomaticConnectionStillReadsLMStudioNativeLists() {
        var lm = RemoteConnection.lmStudioPreset()
        XCTAssertTrue(lm.servesLMStudioTools)
        let urls = LMStudioNativeModels.nativeListURLs(for: lm).map(\.absoluteString)
        XCTAssertEqual(urls, [
            "http://localhost:1234/api/v1/models",
            "http://localhost:1234/api/v0/models",
            "http://localhost:1234/v1/models",
        ])
        lm.encoding = .openAIChatCompletions
        lm.apiBaseURL = "http://localhost:1234/v1"
        XCTAssertFalse(lm.servesLMStudioTools, "the port never decides: LM Studio runs on any port")
        lm.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertTrue(lm.servesLMStudioTools, "LM Studio's own model list does")
    }
}

final class ChatCompletionsToolRoundTripWireTests: XCTestCase {
    @MainActor
    func testSecondAgentRoundSendsToolCallsAndToolCallIDs() async throws {
        let defaults = UserDefaults(suiteName: "roundtrip-\(UUID().uuidString)")!
        let settings = ProviderSettings(
            defaults: defaults,
            apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore())
        )
        let connection = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: "http://127.0.0.1:1234/v1",
            defaultModel: "qwen3.8-27b",
            availableModels: ["qwen3.8-27b"],
            encoding: .automatic
        )
        settings.updateConnection(connection)
        ServiceWireStub.requests = []
        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_read","function":{"name":"lookup","arguments":"{\\"input\\":\\"hi\\"}"}}]}}]}

        data: [DONE]

        """
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "qwen3.8-27b")
        let tool: [String: Any] = [
            "type": "function",
            "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]],
        ]
        let first = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "look this up")],
            tools: [tool],
            toolNames: ["lookup"]
        )
        XCTAssertEqual(first.toolBlocks.map(\.callID), ["call_read"])

        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"content":"done"}}]}

        data: [DONE]

        """
        _ = try await service.agentRound(
            history: [
                LLMChatTurn(role: "user", content: "look this up"),
                LLMChatTurn(role: "assistant", content: ""),
            ],
            tools: [tool],
            toolNames: ["lookup"],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "call_read", output: "found it")]
        )
        let second = try XCTUnwrap(ServiceWireStub.requests.last)
        XCTAssertTrue(second.url.contains("/chat/completions"), second.url)
        let messages = try XCTUnwrap(second.body["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.last(where: { ($0["role"] as? String) == "assistant" }))
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_read")
        let toolMessage = try XCTUnwrap(messages.last(where: { ($0["role"] as? String) == "tool" }))
        XCTAssertEqual(toolMessage["tool_call_id"] as? String, "call_read")
        XCTAssertEqual(toolMessage["content"] as? String, "found it")
        XCTAssertNotNil(second.body["tools"])
    }

    @MainActor
    func testThirdRoundKeepsFirstToolResultsFromHistory() async throws {
        let defaults = UserDefaults(suiteName: "roundtrip-3-\(UUID().uuidString)")!
        let settings = ProviderSettings(
            defaults: defaults,
            apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore())
        )
        let connection = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: "http://127.0.0.1:1234/v1",
            defaultModel: "qwen3.8-27b",
            availableModels: ["qwen3.8-27b"],
            encoding: .automatic
        )
        settings.updateConnection(connection)
        ServiceWireStub.requests = []
        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"lookup","arguments":"{}"}}]}}]}

        data: [DONE]

        """
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "qwen3.8-27b")
        let tool: [String: Any] = [
            "type": "function",
            "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]],
        ]
        _ = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "one")],
            tools: [tool],
            toolNames: ["lookup"]
        )

        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"content":"done"}}]}

        data: [DONE]

        """
        _ = try await service.agentRound(
            history: [
                LLMChatTurn(role: "user", content: "one"),
                LLMChatTurn(role: "assistant", content: "", toolCalls: [
                    EncodedFunctionCall(name: "lookup", arguments: "{}", callID: "call_a"),
                ]),
                LLMChatTurn(role: "tool", content: "first", toolCallID: "call_a"),
                LLMChatTurn(role: "assistant", content: "", toolCalls: [
                    EncodedFunctionCall(name: "lookup", arguments: "{}", callID: "call_b"),
                ]),
                LLMChatTurn(role: "tool", content: "second", toolCallID: "call_b"),
            ],
            tools: [tool],
            toolNames: ["lookup"]
        )
        let messages = try XCTUnwrap(ServiceWireStub.requests.last?.body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool", "assistant", "tool"])
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_a")
        XCTAssertEqual(messages[2]["content"] as? String, "first")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "call_b")
        XCTAssertEqual(messages[4]["content"] as? String, "second")
    }

    @MainActor
    func testEmptyOutputsDoNotAttachStaleLastFunctionCalls() async throws {
        let defaults = UserDefaults(suiteName: "roundtrip-stale-\(UUID().uuidString)")!
        let settings = ProviderSettings(
            defaults: defaults,
            apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore())
        )
        let connection = RemoteConnection(
            name: "LM Studio",
            apiBaseURL: "http://127.0.0.1:1234/v1",
            defaultModel: "qwen3.8-27b",
            availableModels: ["qwen3.8-27b"],
            encoding: .automatic
        )
        settings.updateConnection(connection)
        ServiceWireStub.requests = []
        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_stale","function":{"name":"lookup","arguments":"{}"}}]}}]}

        data: [DONE]

        """
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: "qwen3.8-27b")
        let tool: [String: Any] = [
            "type": "function",
            "function": ["name": "lookup", "description": "d", "parameters": ["type": "object", "properties": [:]]],
        ]
        _ = try await service.agentRound(
            history: [LLMChatTurn(role: "user", content: "one")],
            tools: [tool],
            toolNames: ["lookup"]
        )
        ServiceWireStub.reply = """
        data: {"choices":[{"delta":{"content":"plain"}}]}

        data: [DONE]

        """
        _ = try await service.agentRound(
            history: [
                LLMChatTurn(role: "user", content: "new question"),
                LLMChatTurn(role: "assistant", content: "thinking"),
            ],
            tools: [tool],
            toolNames: ["lookup"]
        )
        let messages = try XCTUnwrap(ServiceWireStub.requests.last?.body["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.last(where: { ($0["role"] as? String) == "assistant" }))
        XCTAssertNil(assistant["tool_calls"])
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "tool" })
    }
}
