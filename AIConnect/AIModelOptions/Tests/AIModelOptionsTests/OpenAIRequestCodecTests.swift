// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

final class OpenAIRequestCodecTests: XCTestCase {
    func testOfficialOpenAIHostDetection() {
        XCTAssertTrue(OpenAIRequestCodec.isOfficialOpenAIHost("https://api.openai.com/v1"))
        XCTAssertTrue(OpenAIRequestCodec.isOfficialOpenAIHost("https://api.openai.com/v1/"))
        XCTAssertFalse(OpenAIRequestCodec.isOfficialOpenAIHost("https://openrouter.ai/api/v1"))
        XCTAssertFalse(OpenAIRequestCodec.isOfficialOpenAIHost("http://localhost:1234/v1"))
        XCTAssertFalse(OpenAIRequestCodec.isOfficialOpenAIHost("https://api.deepseek.com"))
        XCTAssertFalse(
            OpenAIRequestCodec.isOfficialOpenAIHost(
                "https://generativelanguage.googleapis.com/v1beta/openai"
            )
        )
    }

    func testResponsesRoutingForOfficialOpenAI() {
        XCTAssertTrue(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-6-astra",
                hasTools: false
            )
        )
        XCTAssertTrue(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-6-astra",
                hasTools: true
            )
        )
        XCTAssertTrue(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o",
                hasTools: true
            )
        )
        XCTAssertFalse(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o",
                hasTools: false
            )
        )
    }

    func testCompatibleProvidersStayOnChatCompletions() {
        let hosts = [
            "https://openrouter.ai/api/v1",
            "http://localhost:1234/v1",
            "https://api.deepseek.com",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ]
        for host in hosts {
            XCTAssertFalse(
                OpenAIRequestCodec.shouldUseResponsesAPI(
                    baseURL: host,
                    model: "gpt-6-astra",
                    hasTools: true
                ),
                host
            )
        }
    }

    func testResponsesPayloadUsesNestedReasoningEffort() {
        var payload = OpenAIRequestCodec.responsesPayload(
            model: "gpt-6-astra",
            messages: [
                ["role": "system", "content": "Be brief."],
                ["role": "user", "content": "Hi"],
            ],
            stream: true,
            tools: [[
                "type": "function",
                "function": [
                    "name": "list_notes",
                    "description": "List notes",
                    "parameters": ["type": "object"] as [String: Any],
                ] as [String: Any],
            ]]
        )
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .xhigh, rememberThinking: true),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )

        XCTAssertEqual(payload["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(payload["instructions"] as? String, "Be brief.")
        XCTAssertEqual(payload["truncation"] as? String, "auto")
        XCTAssertEqual(payload["store"] as? Bool, true)
        XCTAssertEqual(payload["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 128_000)

        let reasoning = payload["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "xhigh")
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")

        let tools = payload["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["type"] as? String, "function")
        XCTAssertEqual(tools?.first?["name"] as? String, "list_notes")
        XCTAssertNil(tools?.first?["function"])

        let input = payload["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 1)
        XCTAssertEqual(input?.first?["role"] as? String, "user")
    }

    func testAstraNeverEncodesMinimalOrOmitsEffort() {
        var payload: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .minimal),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )
        let reasoning = payload["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")
        XCTAssertNotEqual(reasoning?["effort"] as? String, "none")
        XCTAssertNotEqual(reasoning?["effort"] as? String, "minimal")

        var empty: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(),
            to: &empty,
            model: "gpt-6-astra",
            api: .chatCompletions
        )
        XCTAssertEqual(empty["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(empty["max_completion_tokens"] as? Int, 128_000)
    }

    func testChatCompletionsKeepsReasoningEffortForGPT5() {
        var payload: [String: Any] = [
            "model": "gpt-5.6-sol",
            "messages": [] as [[String: String]],
            "stream": true,
        ]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high, maxOutputTokens: 8192),
            to: &payload,
            model: "gpt-5.6-sol",
            api: .chatCompletions
        )
        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
        XCTAssertNil(payload["reasoning"])
        XCTAssertEqual(payload["max_completion_tokens"] as? Int, 8192)
    }

    func testChatCompletionsSkipsEffortForClassicModels() {
        var payload: [String: Any] = ["model": "gpt-4o"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .low, maxOutputTokens: 2048),
            to: &payload,
            model: "gpt-4o",
            api: .chatCompletions
        )
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertEqual(payload["max_tokens"] as? Int, 2048)
    }

    func testEmptyOptionsLeaveClassicChatPayloadUntouched() {
        var payload: [String: Any] = [
            "model": "gpt-5.6-sol",
            "stream": true,
            "max_completion_tokens": 4096,
        ]
        let before = payload as NSDictionary
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(),
            to: &payload,
            model: "gpt-5.6-sol",
            api: .chatCompletions
        )
        XCTAssertEqual(payload as NSDictionary, before)
        XCTAssertNil(payload["reasoning_effort"])
    }

    func testContextTruncationKeepsSystemAndNewestTurns() {
        let messages: [[String: String]] = [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": String(repeating: "a", count: 400)],
            ["role": "assistant", "content": String(repeating: "b", count: 400)],
            ["role": "user", "content": "latest"],
        ]
        let truncated = OpenAIRequestCodec.truncateMessages(
            messages,
            contextWindowTokens: 40,
            reservedOutputTokens: 20
        )
        XCTAssertEqual(truncated.first?["role"], "system")
        XCTAssertEqual(truncated.last?["content"], "latest")
        XCTAssertLessThan(truncated.count, messages.count)
    }

    func testResponsesCompletionAndStreamingParse() throws {
        let json = """
        {"id":"resp_1","output_text":"Hello Astra","output":[{"type":"message","content":[{"type":"output_text","text":"Hello Astra"}]}]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(OpenAIRequestCodec.parseResponsesCompletion(data), "Hello Astra")

        let delta = """
        {"type":"response.output_text.delta","delta":"Hel"}
        """
        XCTAssertEqual(OpenAIRequestCodec.parseResponsesStreamingDelta(delta), "Hel")

        let chatChunk = """
        {"choices":[{"delta":{"content":"nope"}}]}
        """
        XCTAssertNil(OpenAIRequestCodec.parseResponsesStreamingDelta(chatChunk))
        XCTAssertNil(OpenAIRequestCodec.parseResponsesCompletion(Data(chatChunk.utf8)))
    }

    func testResponsesToolCallAccumulation() {
        var accumulator = OpenAIRequestCodec.ResponsesToolCallAccumulator()
        accumulator.append(json: """
        {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"list_notes","call_id":"call_1","arguments":""}}
        """)
        accumulator.append(json: """
        {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"input\\":\\""}
        """)
        accumulator.append(json: """
        {"type":"response.function_call_arguments.delta","output_index":0,"delta":"hi\\"}"}
        """)
        let calls = accumulator.finish()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "list_notes")
        XCTAssertEqual(calls.first?.callID, "call_1")
        XCTAssertTrue(calls.first?.arguments.contains("hi") == true)
    }

    func testRememberThinkingDefaultsOnForAstra() {
        var payload: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )
        XCTAssertEqual(payload["store"] as? Bool, true)
        XCTAssertEqual(payload["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testRememberThinkingOffClearsStoreButKeepsEncryptedReasoning() {
        var payload: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(rememberThinking: false),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testResponsesPayloadResendsFunctionCallsWhenNotChaining() throws {
        let history = [
            ChatCompletionMessage(role: "user", content: "look this up"),
            ChatCompletionMessage(
                role: "assistant",
                content: "",
                toolCalls: [ChatCompletionToolCall(id: "call_1", name: "lookup", arguments: #"{"q":"one"}"#)]
            ),
            ChatCompletionMessage(role: "tool", content: "one", toolCallID: "call_1"),
            ChatCompletionMessage(
                role: "assistant",
                content: "",
                toolCalls: [ChatCompletionToolCall(id: "call_2", name: "lookup", arguments: #"{"q":"two"}"#)]
            ),
            ChatCompletionMessage(role: "tool", content: "two", toolCallID: "call_2"),
        ]
        let payload = OpenAIRequestCodec.responsesPayload(
            model: "gpt-6-astra",
            typedMessages: history,
            stream: true,
            tools: [[
                "type": "function",
                "function": ["name": "lookup", "parameters": ["type": "object"] as [String: Any]],
            ]]
        )
        XCTAssertNil(payload["previous_response_id"])
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, [
            "user", "function_call", "function_call_output", "function_call", "function_call_output",
        ])
        XCTAssertEqual(input[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[1]["name"] as? String, "lookup")
        XCTAssertEqual(input[1]["arguments"] as? String, #"{"q":"one"}"#)
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["output"] as? String, "one")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_2")
        XCTAssertEqual(input[4]["call_id"] as? String, "call_2")
        XCTAssertEqual(input[4]["output"] as? String, "two")
    }

    func testResponsesPayloadKeepsCurrentRoundCallWhenOutputsArePassedSeparately() throws {
        let payload = OpenAIRequestCodec.responsesPayload(
            model: "gpt-6-astra",
            typedMessages: [ChatCompletionMessage(role: "user", content: "What is my horoscope?")],
            stream: false,
            functionCalls: [EncodedFunctionCall(name: "get_horoscope", arguments: #"{"sign":"Aquarius"}"#, callID: "call_abc")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "call_abc", output: "Next Tuesday.")]
        )
        XCTAssertNil(payload["previous_response_id"])
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, [
            "user", "function_call", "function_call_output",
        ])
        XCTAssertEqual(input[1]["call_id"] as? String, "call_abc")
        XCTAssertEqual(input[1]["name"] as? String, "get_horoscope")
        XCTAssertEqual(input[2]["output"] as? String, "Next Tuesday.")
    }

    func testResponsesPayloadOmitsPriorFunctionCallsWhenChaining() throws {
        let history = [
            ChatCompletionMessage(role: "user", content: "look this up"),
            ChatCompletionMessage(
                role: "assistant",
                content: "",
                toolCalls: [ChatCompletionToolCall(id: "call_1", name: "lookup", arguments: "{}")]
            ),
        ]
        let payload = OpenAIRequestCodec.responsesPayload(
            model: "gpt-6-astra",
            typedMessages: history,
            stream: true,
            previousResponseID: "resp_123",
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "call_1", output: "found")]
        )
        XCTAssertEqual(payload["previous_response_id"] as? String, "resp_123")
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, [
            "user", "function_call_output",
        ])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_1")
        XCTAssertFalse(input.contains { $0["type"] as? String == "function_call" })
    }

    func testStoredMaxOutputStillEncoded() {
        var payload: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(maxOutputTokens: 8_192),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 8_192)
    }

    func testXAIHostUsesResponsesForGrok() {
        XCTAssertTrue(OpenAIRequestCodec.isXAIHost("https://api.x.ai/v1"))
        XCTAssertTrue(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.x.ai/v1",
                model: "grok-4.7",
                hasTools: false
            )
        )
        XCTAssertFalse(
            OpenAIRequestCodec.shouldUseResponsesAPI(
                baseURL: "https://api.x.ai/v1",
                model: "grok-imagine-image-2.0",
                hasTools: false
            )
        )
    }

    func testDocumentedFunctionCallOutputRoundTrip() {
        // Shape from https://developers.openai.com/api/docs/guides/function-calling
        let payload = OpenAIRequestCodec.responsesPayload(
            model: "gpt-6-astra",
            messages: [
                ["role": "user", "content": "What is my horoscope? I am an Aquarius."],
            ],
            stream: false,
            tools: [[
                "type": "function",
                "function": [
                    "name": "get_horoscope",
                    "description": "Get today's horoscope",
                    "parameters": ["type": "object"] as [String: Any],
                ] as [String: Any],
            ]],
            previousResponseID: "resp_123",
            functionCallOutputs: [
                EncodedFunctionCallOutput(
                    callID: "call_abc",
                    output: "Aquarius: Next Tuesday you will befriend a baby otter."
                ),
            ]
        )
        XCTAssertEqual(payload["previous_response_id"] as? String, "resp_123")
        let input = payload["input"] as? [[String: Any]]
        XCTAssertEqual(input?.last?["type"] as? String, "function_call_output")
        XCTAssertEqual(input?.last?["call_id"] as? String, "call_abc")
        let tools = payload["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "get_horoscope")
        XCTAssertNil(tools?.first?["function"])
    }

    func testResponsesErrorIsSurfacedFromDocumentedErrorObject() throws {
        let json = """
        {"error":{"message":"Invalid reasoning.effort: none is not supported for gpt-6-astra.","type":"invalid_request_error"}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(
            OpenAIRequestCodec.responsesCompletionError(in: data),
            "Invalid reasoning.effort: none is not supported for gpt-6-astra."
        )
        XCTAssertNil(OpenAIRequestCodec.parseResponsesCompletion(data))
    }

    func testDocumentedStreamingEvents() {
        let delta = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.output_text.delta","delta":"Hel"}"#
        )
        XCTAssertEqual(delta?.textDelta, "Hel")

        let completed = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.completed","response":{"id":"resp_1","output_text":"Hello Astra"}}"#
        )
        XCTAssertEqual(completed?.responseID, "resp_1")
        XCTAssertEqual(completed?.completedOutputText, "Hello Astra")
        XCTAssertTrue(completed?.isTerminal == true)

        let withUsage = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.completed","response":{"id":"resp_2","output_text":"Hi","usage":{"input_tokens":9,"output_tokens":2}}}"#
        )
        XCTAssertEqual(withUsage?.usage?.inputTokens, 9)
        XCTAssertEqual(withUsage?.usage?.outputTokens, 2)

        let failed = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.failed","response":{"error":{"message":"server error"}}}"#
        )
        XCTAssertEqual(failed?.errorMessage, "server error")
        XCTAssertTrue(failed?.isTerminal == true)

        let partDone = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.output_text.done","text":"Hello Astra"}"#
        )
        XCTAssertEqual(partDone?.completedOutputText, "Hello Astra")
        XCTAssertNil(partDone?.textDelta)
    }

    func testParseModelsListKeepsCreatedTimestamps() throws {
        let json = """
        {"data":[
          {"id":"gpt-4o","created":1715558400},
          {"id":"gpt-6-astra","created":1777507200},
          {"id":"gpt-6-luna","created":1779062400}
        ]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let models = try OpenAIRequestCodec.parseModelsList(data)
        XCTAssertEqual(
            ModelCapabilityCatalog.newestChatModels(models, limit: 2),
            ["gpt-6-luna", "gpt-6-astra"]
        )
    }

    func testParseModelsListAcceptsChatGPTPlanCatalogSlugs() throws {
        let json = """
        {"models":[
          {"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},
          {"slug":"hidden-model","display_name":"Hidden","visibility":"none"}
        ]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let models = try OpenAIRequestCodec.parseModelsList(data)
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol"])
    }

    func testReasoningModeEncodedForGPT6() {
        var payload: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high, reasoningMode: "pro"),
            to: &payload,
            model: "gpt-6-astra",
            api: .responses
        )
        let reasoning = payload["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
        XCTAssertEqual(reasoning?["mode"] as? String, "pro")
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
    }

    func testReasoningSummaryRequestedOnlyWhenSupported() {
        var astra: [String: Any] = ["model": "gpt-6-astra"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .medium),
            to: &astra,
            model: "gpt-6-astra",
            api: .responses
        )
        XCTAssertEqual((astra["reasoning"] as? [String: Any])?["summary"] as? String, "auto")

        var liveOnly: [String: Any] = ["model": "qwen3.8-flash-next"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high),
            to: &liveOnly,
            model: "qwen3.8-flash-next",
            api: .responses,
            live: LiveModelCapabilities(reasoningEfforts: [.high], defaultReasoningEffort: .high)
        )
        XCTAssertEqual((liveOnly["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil((liveOnly["reasoning"] as? [String: Any])?["summary"])
    }

    func testReasoningSummaryDeltasAreParsed() {
        let delta = OpenAIRequestCodec.parseResponsesStreamEvent(
            #"{"type":"response.reasoning_summary_text.delta","delta":"Considering the files"}"#
        )
        XCTAssertEqual(delta?.reasoningDelta, "Considering the files")
        XCTAssertNil(delta?.textDelta)
        XCTAssertEqual(
            StreamTextCodec.classifyReasoning(
                #"{"type":"response.reasoning_summary_text.delta","delta":"Considering the files"}"#
            ),
            "Considering the files"
        )
    }
}

final class ModelGenerationSettingsStoreTests: XCTestCase {
    private let selectionKey = "remote|test-\(UUID().uuidString)|gpt-6-astra"

    override func tearDown() {
        ModelGenerationSettings.setOptions(ModelGenerationOptions(), forSelectionKey: selectionKey)
        super.tearDown()
    }

    func testRoundTripPerSelectionKey() {
        let options = ModelGenerationOptions(
            reasoningEffort: .medium,
            contextWindowTokens: 128_000,
            rememberThinking: true
        )
        ModelGenerationSettings.setOptions(options, forSelectionKey: selectionKey)
        XCTAssertEqual(ModelGenerationSettings.options(forSelectionKey: selectionKey), options)
    }

    func testLegacyConnectionKeyStillLoads() {
        let connectionID = "legacy-\(UUID().uuidString)"
        let options = ModelGenerationOptions(reasoningEffort: .high, maxOutputTokens: 2048)
        var all = [String: ModelGenerationOptions]()
        all["\(connectionID)|gpt-5.6-sol"] = options
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: ModelGenerationSettings.defaultsKey)
        }

        let loaded = ModelGenerationSettings.options(connectionID: connectionID, modelID: "gpt-5.6-sol")
        XCTAssertEqual(loaded.reasoningEffort, .high)
        ModelGenerationSettings.removeOptions(connectionID: connectionID)
        XCTAssertTrue(
            ModelGenerationSettings.options(connectionID: connectionID, modelID: "gpt-5.6-sol").isEmpty
        )
    }
}
