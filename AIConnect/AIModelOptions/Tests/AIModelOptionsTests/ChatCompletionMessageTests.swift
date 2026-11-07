// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

final class ChatCompletionMessageTests: XCTestCase {
    func testRoundTripJSONHasToolCallsAndToolCallID() {
        let messages = ChatCompletionToolRoundTrip.applying(
            to: [ChatCompletionMessage(role: "user", content: "hi")],
            functionCalls: [
                EncodedFunctionCall(name: "lookup", arguments: #"{"q":"a"}"#, callID: "c1"),
                EncodedFunctionCall(name: "search", arguments: "{}", callID: "c2"),
            ],
            functionCallOutputs: [
                EncodedFunctionCallOutput(callID: "c1", output: "A"),
                EncodedFunctionCallOutput(callID: "c2", output: "B"),
            ]
        )
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].toolCalls.map(\.id), ["c1", "c2"])
        XCTAssertEqual(messages[2].toolCallID, "c1")
        XCTAssertEqual(messages[3].toolCallID, "c2")
        let objects = messages.map(\.jsonObject)
        XCTAssertEqual((objects[1]["tool_calls"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(objects[2]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(objects[2]["role"] as? String, "tool")
    }

    func testDoesNotDuplicateExistingToolResults() {
        let existing = [
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [
                ChatCompletionToolCall(id: "c1", name: "lookup", arguments: "{}"),
            ]),
            ChatCompletionMessage(role: "tool", content: "done", toolCallID: "c1"),
        ]
        let again = ChatCompletionToolRoundTrip.applying(
            to: existing,
            functionCalls: [EncodedFunctionCall(name: "lookup", arguments: "{}", callID: "c1")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "c1", output: "done")]
        )
        XCTAssertEqual(again.filter { $0.role == "tool" }.count, 1)
    }

    func testDictionaryInitKeepsToolCallID() {
        let message = ChatCompletionMessage(dictionary: [
            "role": "tool",
            "content": "found",
            "tool_call_id": "call_1",
        ])
        XCTAssertEqual(message.role, "tool")
        XCTAssertEqual(message.toolCallID, "call_1")
        XCTAssertEqual(message.jsonObject["tool_call_id"] as? String, "call_1")
    }
}
