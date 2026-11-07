// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

/// Responses request shape for ChatGPT plan usage (preview limitations doc).
final class ChatGPTPlanRequestTests: XCTestCase {
    func testPlanPayloadStreamsWithoutStoreAndDropsUnsupportedFields() {
        var payload: [String: Any] = [
            "model": "gpt-6.1-sol",
            "input": [["role": "user", "content": "hi"]],
            "stream": false,
            "store": true,
            "include": ["reasoning.encrypted_content"],
            "previous_response_id": "resp_1",
            "temperature": 0.7,
            "top_p": 0.9,
            "max_output_tokens": 4096,
            "truncation": "auto",
            "metadata": ["a": "b"],
            "user": "u",
            "background": true,
            "conversation": "c",
            "max_tool_calls": 3,
            "prompt": ["id": "p"],
            "prompt_cache_retention": "24h",
            "safety_identifier": "s",
            "top_logprobs": 2,
            "moderation": "auto",
            "multi_agent": true,
            "reasoning": ["effort": "medium"],
        ]
        OpenAIRequestCodec.applyChatGPTPlanRequirements(to: &payload)
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["store"] as? Bool, false)
        for key in OpenAIRequestCodec.chatGPTPlanUnsupportedFields {
            XCTAssertNil(payload[key], "\(key) must be omitted")
        }
        XCTAssertNil(payload["previous_response_id"])
        XCTAssertNil(payload["include"])
        XCTAssertNil(payload["temperature"])
        XCTAssertNil(payload["max_output_tokens"])
        XCTAssertEqual((payload["reasoning"] as? [String: String])?["effort"], "medium", "Reasoning effort is allowed")
        XCTAssertEqual(payload["model"] as? String, "gpt-6.1-sol")
    }

    func testPlanPayloadSendsFullHistoryAndSystemAsInstructions() throws {
        let messages: [[String: String]] = [
            ["role": "system", "content": "Be brief."],
            ["role": "user", "content": "one"],
            ["role": "assistant", "content": "two"],
            ["role": "user", "content": "three"],
        ]
        let payload = OpenAIRequestCodec.chatGPTPlanPayload(model: "gpt-6.1-sol", messages: messages)
        XCTAssertEqual(payload["instructions"] as? String, "Be brief.")
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3, "Full history, no previous_response_id")
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertFalse(input.contains { ($0["role"] as? String) == "system" }, "System items are rejected on this route")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertNil(payload["previous_response_id"])
        XCTAssertNil(payload["temperature"])
        XCTAssertNil(payload["max_output_tokens"])
        // Must serialize as JSON.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testPlanPayloadKeepsFunctionToolsAndOutputs() throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "lookup", "description": "d", "parameters": ["type": "object"]],
        ]]
        let payload = OpenAIRequestCodec.chatGPTPlanPayload(
            model: "gpt-6.1-sol",
            messages: [["role": "user", "content": "q"]],
            tools: tools,
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "call_1", output: "42")]
        )
        let encodedTools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(encodedTools.first?["name"] as? String, "lookup")
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    }

    func testPlanPayloadResendsFunctionCallsFromTypedHistory() throws {
        let history = [
            ChatCompletionMessage(role: "user", content: "q"),
            ChatCompletionMessage(
                role: "assistant",
                content: "",
                toolCalls: [ChatCompletionToolCall(id: "call_1", name: "lookup", arguments: "{}")]
            ),
            ChatCompletionMessage(role: "tool", content: "42", toolCallID: "call_1"),
        ]
        let payload = OpenAIRequestCodec.chatGPTPlanPayload(
            model: "gpt-6.1-sol",
            typedMessages: history,
            tools: [[
                "type": "function",
                "function": ["name": "lookup", "description": "d", "parameters": ["type": "object"]],
            ]]
        )
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertNil(payload["previous_response_id"])
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, [
            "user", "function_call", "function_call_output",
        ])
        XCTAssertEqual(input[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["output"] as? String, "42")
    }
}
