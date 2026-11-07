// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// Regression: asking "What is today's date" ran `current_date`, then the follow-up failed with
/// "Generation failed: HTTP 500: <!DOCTYPE html>…Internal Server Error" from LM Studio,
/// on both the Harmony and the Chat Completions connection.
/// The follow-up resent the call with `arguments` set to the tool's extracted input ("" for
/// `current_date`'s `{}`), which LM Studio can't parse as JSON. History must keep the model's JSON.
final class ToolHistoryArgumentsWireTests: XCTestCase {
    static let currentDate: [String: Any] = [
        "type": "function",
        "function": ["name": "current_date", "description": "Today's date and time.",
                     "parameters": ["type": "object", "properties": [:]]],
    ]
    static let webSearch: [String: Any] = [
        "type": "function",
        "function": ["name": "web_search", "description": "Search the web.",
                     "parameters": ["type": "object", "properties": ["query": ["type": "string"], "count": ["type": "integer"]],
                                    "required": ["query"]]],
    ]

    /// Runs the agent loop's two rounds the way AgentLoopService does and returns the follow-up messages.
    @MainActor
    private func followUp(encoding: RemoteProtocolEncoding, model: String, toolStream: String,
                          tools: [[String: Any]], names: Set<String>) async throws -> [[String: Any]] {
        let defaults = UserDefaults(suiteName: "tool-args-\(UUID().uuidString)")!
        let settings = ProviderSettings(defaults: defaults,
                                        apiKeyStore: RemoteAPIKeyStore(defaults: defaults, secureStore: MemorySecureStore()))
        let connection = RemoteConnection(name: "LM Studio", apiBaseURL: "http://192.168.1.100:1234/v1",
                                          defaultModel: model, availableModels: [model], encoding: encoding)
        settings.updateConnection(connection)
        ServiceWireStub.requests = []
        ServiceWireStub.reply = toolStream
        let service = RemoteLLMService(settings: settings, session: ServiceWireStub.session)
        service.setActiveConnection(id: connection.id, modelID: model)

        var history = [LLMChatTurn(role: "user", content: "What is today's date")]
        let first = try await service.agentRound(history: history, tools: tools, toolNames: names)
        XCTAssertFalse(first.toolBlocks.isEmpty, "the sample should parse as a tool call")
        let assigned = LLMChatToolHistory.assigningCallIDs(first.toolBlocks)
        history.append(LLMChatToolHistory.assistantTurn(text: first.text, blocks: assigned))
        let outputs = assigned.map { EncodedFunctionCallOutput(callID: $0.callID ?? "", output: "Thursday, October 22, 2026, 6:09 PM PDT") }
        history.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: outputs))

        ServiceWireStub.reply = "data: {\"choices\":[{\"delta\":{\"content\":\"It's Thursday.\"}}]}\n\ndata: [DONE]\n\n"
        _ = try await service.agentRound(history: history, tools: tools, toolNames: names, functionCallOutputs: outputs)
        return try XCTUnwrap(ServiceWireStub.requests.last?.body["messages"] as? [[String: Any]])
    }

    private func sentArguments(_ messages: [[String: Any]]) throws -> [String] {
        let assistant = try XCTUnwrap(messages.last { ($0["role"] as? String) == "assistant" })
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        return calls.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
    }

    @MainActor
    func testQwenOnChatCompletionsResendsEmptyObjectForCurrentDate() async throws {
        // LM Studio 0.4 stream for qwen/qwen3.8-27b (numeric call id, `{}` arguments).
        let stream = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"614219738","type":"function","function":{"name":"current_date","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"qwen/qwen3.8-27b","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let messages = try await followUp(encoding: .openAIChatCompletions, model: "qwen/qwen3.8-27b", toolStream: stream,
                                          tools: [Self.currentDate], names: ["current_date"])
        XCTAssertEqual(try sentArguments(messages), ["{}"])
        let tool = try XCTUnwrap(messages.last)
        XCTAssertEqual(tool["role"] as? String, "tool")
        XCTAssertEqual(tool["tool_call_id"] as? String, "614219738")
    }

    @MainActor
    func testGPTOSSOnHarmonyResendsEmptyObjectForCurrentDate() async throws {
        let stream = """
        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"openai/gpt-oss-20b","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"Need the date. Call current_date."},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"openai/gpt-oss-20b","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"171830421","type":"function","function":{"name":"current_date","arguments":"{}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"openai/gpt-oss-20b","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let messages = try await followUp(encoding: .lmStudioHarmony, model: "openai/gpt-oss-20b", toolStream: stream,
                                          tools: [Self.currentDate], names: ["current_date"])
        XCTAssertEqual(try sentArguments(messages), ["{}"])
    }

    @MainActor
    func testArgumentsWithValuesAreResentExactly() async throws {
        let raw = #"{"query":"weather in Paris","count":3}"#
        let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
        let stream = """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_ws","type":"function","function":{"name":"web_search","arguments":"\(escaped)"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let messages = try await followUp(encoding: .openAIChatCompletions, model: "qwen/qwen3.8-27b", toolStream: stream,
                                          tools: [Self.webSearch], names: ["web_search"])
        XCTAssertEqual(try sentArguments(messages), [raw])
    }

    func testFencedToolBlockGoesBackAsJSON() throws {
        // A text-parsed ```web_search block has no native arguments, only its body.
        let turn = LLMChatToolHistory.assistantTurn(text: "```web_search\nweather in Paris\n```",
                                                    blocks: [ToolCallBlock(toolType: "web_search", content: "weather in Paris", callID: "call_1")])
        let call = try XCTUnwrap(turn.chatMessage.toolCalls.first)
        let arguments = try XCTUnwrap((call.jsonObject["function"] as? [String: Any])?["arguments"] as? String)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(object["input"] as? String, "weather in Paris")
    }

    func testAssigningCallIDsKeepsTheModelsArguments() throws {
        let block = try XCTUnwrap(ToolCallParsing.toolBlock(from: [
            "function": ["name": "web_search", "arguments": #"{"query":"weather in Paris","count":3}"#],
        ]))
        let turn = LLMChatToolHistory.assistantTurn(text: "", blocks: LLMChatToolHistory.assigningCallIDs([block]))
        XCTAssertEqual(turn.toolCalls.first?.arguments, #"{"query":"weather in Paris","count":3}"#)
        XCTAssertEqual(block.content, "weather in Paris", "tools still get the extracted input")
    }
}
