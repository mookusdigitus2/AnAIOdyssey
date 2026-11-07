// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// Regression: a chat against LM Studio, right after a successful web_search tool call, failed with
/// "Generation failed: Engine protocol predict request returned 400: Cannot continue an assistant message
/// that contains tool calls." With a small loaded context the follow-up went out as
/// `[system, tool, assistant(tool_calls)]`. llama.cpp prefills a trailing assistant and refuses one with calls.
final class ToolRoundContinueWireTests: XCTestCase {
    static let webSearch: [String: Any] = [
        "type": "function",
        "function": ["name": "web_search", "description": "Search the web.",
                     "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
    ]
    static let prompt = "Can you tell me the history of Iron Heart selvedge denim, specifically the 21 ounce weight?"
    static let model = "qwen/qwen3.8-27b"

    static func webResult(_ chars: Int) -> String {
        "<external>\n" + String(repeating: "Iron Heart 21oz selvedge history. ", count: chars / 34) + "\n</external>"
    }

    /// Runs both agent rounds the way AgentLoopService does, with an 8k loaded context, a
    /// 10k-character system prompt and a 16k-character web_search result. Returns the follow-up body.
    @MainActor
    private func followUpBody(apiChoice: OpenAIAPIChoice?, toolStream: String,
                              extraTools: [[String: Any]] = []) async throws -> [String: Any] {
        let defaults = UserDefaults(suiteName: "tool-round-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults,
                                        apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        let connection = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:1234/v1",
                                          defaultModel: Self.model, availableModels: [Self.model],
                                          encoding: .openAIChatCompletions, openAIAPI: apiChoice)
        settings.updateConnection(connection)
        ModelGenerationSettings.setOptions(ModelGenerationOptions(contextWindowTokens: 8192), connectionID: connection.id, modelID: Self.model)
        defer { ModelGenerationSettings.setOptions(ModelGenerationOptions(), connectionID: connection.id, modelID: Self.model) }
        ServiceWireStub.requests = []
        ServiceWireStub.reply = toolStream
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: Self.model)

        var history = [
            LLMChatTurn(role: "system", content: String(repeating: "s", count: 10_000)),
            LLMChatTurn(role: "user", content: "What is today's date?"),
            LLMChatTurn(role: "assistant", content: "Today is Friday, October 23, 2026."),
            LLMChatTurn(role: "user", content: Self.prompt),
        ]
        let tools = [Self.webSearch] + extraTools
        let first = try await service.agentRound(history: history, tools: tools, toolNames: ["web_search"])
        XCTAssertFalse(first.toolBlocks.isEmpty, "the sample should parse as a tool call")
        let assigned = LLMChatToolHistory.assigningCallIDs(first.toolBlocks)
        history.append(LLMChatToolHistory.assistantTurn(text: first.text, blocks: assigned))
        let outputs = assigned.map { EncodedFunctionCallOutput(callID: $0.callID ?? "", output: Self.webResult(16_000)) }
        history.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: outputs))

        ServiceWireStub.reply = "data: {\"choices\":[{\"delta\":{\"content\":\"Iron Heart started in 1989.\"}}]}\n\ndata: [DONE]\n\n"
        _ = try await service.agentRound(history: history, tools: tools, toolNames: ["web_search"], functionCallOutputs: outputs)
        return try XCTUnwrap(ServiceWireStub.requests.last?.body)
    }

    @MainActor
    func testChatCompletionsFollowUpEndsWithTheShortenedResult() async throws {
        let stream = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"348203947","type":"function","function":{"name":"web_search","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"query\\":\\"Iron Heart 21oz history\\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let body = try await followUpBody(apiChoice: nil, toolStream: stream)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let roles = messages.map { ($0["role"] as? String ?? "") + ($0["tool_calls"] == nil ? "" : "(tool_calls)") }
        XCTAssertEqual(roles.first, "system")
        XCTAssertEqual(Array(roles.suffix(3)), ["user", "assistant(tool_calls)", "tool"], "\(roles)")
        XCTAssertTrue(messages.dropLast(2).last?["content"] as? String == Self.prompt, "the user prompt stays right before the call")
        let calls = try XCTUnwrap(messages.dropLast().last?["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "348203947")
        let tool = try XCTUnwrap(messages.last)
        XCTAssertEqual(tool["tool_call_id"] as? String, "348203947")
        let content = try XCTUnwrap(tool["content"] as? String)
        XCTAssertLessThan(content.count, Self.webResult(16_000).count)
        XCTAssertGreaterThan(content.count, 10_000, "an 8k window keeps a 2k output reserve, not 4k")
        XCTAssertTrue(content.hasSuffix("</external>"))
    }

    @MainActor
    func testResponsesFollowUpKeepsTheCallBeforeItsOutput() async throws {
        let stream = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"web_search","call_id":"call_ws","arguments":"{\\"query\\":\\"Iron Heart 21oz history\\"}"}}

        data: [DONE]

        """
        let body = try await followUpBody(apiChoice: .responses, toolStream: stream)
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let kinds = input.map { ($0["type"] as? String) ?? (($0["role"] as? String) ?? "") }
        XCTAssertEqual(Array(kinds.suffix(3)), ["user", "function_call", "function_call_output"], "\(kinds)")
        XCTAssertTrue(input.dropLast(2).last?["content"] as? String == Self.prompt, "the user prompt stays right before the call")
        XCTAssertEqual(input.dropLast().last?["call_id"] as? String, "call_ws")
        XCTAssertEqual(input.last?["call_id"] as? String, "call_ws")
        let output = try XCTUnwrap(input.last?["output"] as? String)
        XCTAssertGreaterThan(output.count, 10_000)
        XCTAssertLessThan(output.count, Self.webResult(16_000).count)
    }

    /// Odyssey sends every enabled tool's schema with each request. Those tokens come out of
    /// the same window, so the history is trimmed to what is left after them.
    @MainActor
    func testToolSchemasCountAgainstTheWindow() async throws {
        let stream = """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"348203947","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"Iron Heart 21oz history\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let extra: [[String: Any]] = (1...20).map { index in
            ["type": "function",
             "function": ["name": "tool_\(index)",
                          "description": String(repeating: "Does one careful thing for the user. ", count: 10),
                          "parameters": ["type": "object", "properties": ["input": ["type": "string"]]]]]
        }
        let body = try await followUpBody(apiChoice: nil, toolStream: stream, extraTools: extra)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        let historyTokens = messages.map(ChatCompletionMessage.init(sent:)).reduce(0) { $0 + OpenAIRequestCodec.estimatedTokens(in: $1) }
        let toolData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(body["tools"] as? [[String: Any]]))
        let schemaTokens = (toolData.count + 3) / 4
        XCTAssertGreaterThan(schemaTokens, 1500)
        XCTAssertLessThanOrEqual(historyTokens + schemaTokens, 8192 - 2048, "history \(historyTokens) + tools \(schemaTokens)")
    }
}

private extension ChatCompletionMessage {
    init(sent object: [String: Any]) {
        let calls = (object["tool_calls"] as? [[String: Any]] ?? []).map { call in
            let function = call["function"] as? [String: Any] ?? [:]
            return ChatCompletionToolCall(id: call["id"] as? String ?? "",
                                          name: function["name"] as? String ?? "",
                                          arguments: function["arguments"] as? String ?? "")
        }
        self.init(role: object["role"] as? String ?? "", content: object["content"] as? String ?? "",
                  toolCalls: calls, toolCallID: object["tool_call_id"] as? String)
    }
}
