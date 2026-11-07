// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Regression: a chat against LM Studio, right after a web_search tool call, failed with
/// "Engine protocol predict request returned 400: Cannot continue an assistant message that contains tool calls."
/// Truncation kept `[system, tool]` and dropped the call, then the round-trip appended `assistant(tool_calls)`
/// after the result. llama.cpp treats a trailing assistant as a prefill and refuses one with tool calls.
final class ToolRoundRequestShapeTests: XCTestCase {
    private func call(_ id: String, _ name: String = "web_search") -> ChatCompletionToolCall {
        ChatCompletionToolCall(id: id, name: name, arguments: #"{"query":"Iron Heart 21oz history"}"#)
    }

    private func encoded(_ id: String, _ name: String = "web_search") -> EncodedFunctionCall {
        EncodedFunctionCall(name: name, arguments: #"{"query":"Iron Heart 21oz history"}"#, callID: id)
    }

    private func webResult(_ chars: Int) -> String {
        "<external>\n" + String(repeating: "Iron Heart 21oz selvedge history. ", count: max(chars / 34, 1)) + "\n</external>"
    }

    private func shape(_ messages: [ChatCompletionMessage]) -> [String] {
        messages.map { $0.role + ($0.toolCalls.isEmpty ? "" : "(tool_calls)") }
    }

    private func tokens(_ messages: [ChatCompletionMessage]) -> Int {
        messages.reduce(0) { $0 + OpenAIRequestCodec.estimatedTokens(in: $1) }
    }

    /// Every tool message answers a call made earlier in the same request, and every
    /// assistant(tool_calls) turn is followed straight away by all of its results.
    private func assertRoundsIntact(_ messages: [ChatCompletionMessage], file: StaticString = #filePath, line: UInt = #line) {
        var called = Set<String>()
        for (index, message) in messages.enumerated() {
            if message.role == "tool" {
                XCTAssertTrue(called.contains(message.toolCallID ?? ""), "orphan tool message \(message.toolCallID ?? "nil") in \(shape(messages))", file: file, line: line)
            }
            guard message.role == "assistant", !message.toolCalls.isEmpty else { continue }
            message.toolCalls.forEach { called.insert($0.id) }
            let following = messages[(index + 1)...].prefix { $0.role == "tool" }.compactMap(\.toolCallID)
            XCTAssertEqual(Set(following), Set(message.toolCalls.map(\.id)), "results not right after their call in \(shape(messages))", file: file, line: line)
        }
        if let last = messages.last {
            XCTAssertFalse(last.role == "assistant" && !last.toolCalls.isEmpty, "request ends in assistant(tool_calls): \(shape(messages))", file: file, line: line)
        }
    }

    // MARK: Truncation

    /// DRB's reproduction: 8k context, 10k-character system prompt, 16k-character web_search result.
    func testEightKContextKeepsWebSearchCallWithItsShortenedResult() throws {
        let prompt = "Can you tell me the history of Iron Heart selvedge denim, specifically the 21 ounce weight?"
        let result = webResult(16_000)
        let messages = [
            ChatCompletionMessage(role: "system", content: String(repeating: "s", count: 10_000)),
            ChatCompletionMessage(role: "user", content: "What is today's date?"),
            ChatCompletionMessage(role: "assistant", content: "Today is Friday, October 23, 2026."),
            ChatCompletionMessage(role: "user", content: prompt),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("348203947")]),
            ChatCompletionMessage(role: "tool", content: result, toolCallID: "348203947"),
        ]
        let reserved = OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 8192, maxOutputTokens: 32_768)
        let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: 8192, reservedOutputTokens: reserved)

        XCTAssertEqual(truncated.first?.role, "system")
        XCTAssertEqual(Array(shape(truncated).suffix(3)), ["user", "assistant(tool_calls)", "tool"])
        XCTAssertEqual(truncated.dropLast(2).last?.content, prompt)
        let kept = try XCTUnwrap(truncated.last?.content)
        XCTAssertEqual(truncated.last?.toolCallID, "348203947")
        XCTAssertLessThan(kept.count, result.count, "the result is shortened, not the call dropped")
        XCTAssertGreaterThan(kept.count, 10_000, "a small context still leaves most of the window for the result")
        XCTAssertTrue(kept.hasPrefix("<external>"))
        XCTAssertTrue(kept.hasSuffix("</external>"))
        XCTAssertLessThanOrEqual(tokens(truncated), 8192 - reserved)
        assertRoundsIntact(truncated)

        let sent = ChatCompletionToolRoundTrip.applying(
            to: truncated,
            functionCalls: [encoded("348203947")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "348203947", output: result)]
        )
        XCTAssertEqual(sent, truncated, "nothing is re-added once the round is already in the history")
    }

    func testParallelResultsStayWithTheirCall() {
        let messages = [
            ChatCompletionMessage(role: "system", content: "sys"),
            ChatCompletionMessage(role: "user", content: "compare both"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("a"), call("b")]),
            ChatCompletionMessage(role: "tool", content: webResult(8000), toolCallID: "a"),
            ChatCompletionMessage(role: "tool", content: webResult(8000), toolCallID: "b"),
        ]
        let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: 2048, reservedOutputTokens: 512)
        XCTAssertEqual(shape(truncated), ["system", "user", "assistant(tool_calls)", "tool", "tool"])
        XCTAssertEqual(truncated.compactMap(\.toolCallID), ["a", "b"])
        XCTAssertLessThanOrEqual(tokens(truncated), 2048 - 512)
        assertRoundsIntact(truncated)
    }

    func testDroppedRoundTakesItsResultsWithIt() {
        let messages = [
            ChatCompletionMessage(role: "system", content: "sys"),
            ChatCompletionMessage(role: "user", content: "first"),
            ChatCompletionMessage(role: "assistant", content: String(repeating: "r", count: 2000), toolCalls: [call("a")]),
            ChatCompletionMessage(role: "tool", content: String(repeating: "x", count: 400), toolCallID: "a"),
            ChatCompletionMessage(role: "assistant", content: "answer"),
            ChatCompletionMessage(role: "user", content: "next"),
        ]
        let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: 400, reservedOutputTokens: 100)
        XCTAssertFalse(truncated.contains { $0.role == "tool" }, "the result goes when its call goes: \(shape(truncated))")
        XCTAssertEqual(truncated.last?.content, "next")
        assertRoundsIntact(truncated)
    }

    func testMultiRoundTurnKeepsUserPromptAndEveryRound() {
        let messages = [
            ChatCompletionMessage(role: "system", content: "sys"),
            ChatCompletionMessage(role: "user", content: "research it"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("1")]),
            ChatCompletionMessage(role: "tool", content: webResult(8000), toolCallID: "1"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("2", "fetch_page")]),
            ChatCompletionMessage(role: "tool", content: webResult(8000), toolCallID: "2"),
        ]
        let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: 4096, reservedOutputTokens: 1024)
        XCTAssertEqual(shape(truncated), ["system", "user", "assistant(tool_calls)", "tool", "assistant(tool_calls)", "tool"])
        XCTAssertLessThanOrEqual(tokens(truncated), 4096 - 1024)
        assertRoundsIntact(truncated)
    }

    func testSystemPromptOverBudgetStillKeepsTheCurrentRound() {
        let messages = [
            ChatCompletionMessage(role: "system", content: String(repeating: "s", count: 40_000)),
            ChatCompletionMessage(role: "user", content: "search"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("c1")]),
            ChatCompletionMessage(role: "tool", content: webResult(16_000), toolCallID: "c1"),
        ]
        let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: 8192, reservedOutputTokens: 2048)
        XCTAssertEqual(shape(truncated), ["system", "user", "assistant(tool_calls)", "tool"])
        XCTAssertLessThan(truncated.last?.content.count ?? .max, 16_000)
        assertRoundsIntact(truncated)
    }

    func testEveryContextAndResultSizeEndsWithTheToolResult() {
        for context in [4096, 8192, 16_384, 32_768] {
            for resultChars in [500, 4000, 16_000, 64_000] {
                for maxOutput in [4096, 32_768] {
                    let messages = [
                        ChatCompletionMessage(role: "system", content: String(repeating: "s", count: 10_000)),
                        ChatCompletionMessage(role: "user", content: "What is today's date?"),
                        ChatCompletionMessage(role: "assistant", content: "Friday."),
                        ChatCompletionMessage(role: "user", content: "history of Iron Heart 21oz"),
                        ChatCompletionMessage(role: "assistant", content: "Okay, I should search.", toolCalls: [call("348203947")]),
                        ChatCompletionMessage(role: "tool", content: webResult(resultChars), toolCallID: "348203947"),
                    ]
                    let reserved = OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: context, maxOutputTokens: maxOutput)
                    let truncated = OpenAIRequestCodec.truncateMessages(messages, contextWindowTokens: context, reservedOutputTokens: reserved)
                    let sent = ToolRoundRequestGuard.repaired(ChatCompletionToolRoundTrip.applying(
                        to: truncated,
                        functionCalls: [encoded("348203947")],
                        functionCallOutputs: [EncodedFunctionCallOutput(callID: "348203947", output: webResult(resultChars))]
                    ))
                    XCTAssertEqual(sent.last?.role, "tool", "ctx \(context) result \(resultChars) maxOut \(maxOutput): \(shape(sent))")
                    XCTAssertEqual(sent.dropLast(2).last?.content, "history of Iron Heart 21oz", "ctx \(context) result \(resultChars) maxOut \(maxOutput)")
                    XCTAssertNil(ToolRoundRequestGuard.problem(in: sent))
                    assertRoundsIntact(sent)
                }
            }
        }
    }

    /// Web pages, code and JSON run nearer 3 characters per token than 4 (LM Studio counted a
    /// 14,419-character web_search result as 4,666 tokens), so a shortened result is sized at 3.
    func testShortenedResultLeavesRoomForDenseText() {
        let message = ChatCompletionMessage(role: "tool", content: webResult(20_000), toolCallID: "348203947")
        let shortened = OpenAIRequestCodec.shortenedToolResult(message, toTokens: 1000)
        XCTAssertLessThanOrEqual(shortened.content.count, 3000)
        XCTAssertGreaterThan(shortened.content.count, 2900)
        XCTAssertTrue(shortened.content.hasPrefix("<external>"))
        XCTAssertTrue(shortened.content.hasSuffix("</external>"))
        XCTAssertTrue(shortened.content.contains(OpenAIRequestCodec.shortenedToolResultNote))
    }

    // MARK: Output reserve

    func testSmallContextReservesAQuarterForOutput() {
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 8192, maxOutputTokens: 32_768), 2048)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 16_384, maxOutputTokens: 32_768), 4096)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 4096, maxOutputTokens: 32_768), 1024)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 2048, maxOutputTokens: 32_768), 1024)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 8192, maxOutputTokens: 1000), 1000)
        // Large windows keep the old rule: half the window, capped by the model's max output.
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 32_768, maxOutputTokens: 32_768), 16_384)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 262_144, maxOutputTokens: 32_768), 32_768)
        XCTAssertEqual(OpenAIRequestCodec.reservedOutputTokens(contextWindowTokens: 128_000, maxOutputTokens: 4096), 4096)
    }

    // MARK: Round-trip placement

    func testApplyingPutsTheCallBeforeItsResult() {
        let result = ChatCompletionToolRoundTrip.applying(
            to: [
                ChatCompletionMessage(role: "system", content: "s"),
                ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
            ],
            functionCalls: [encoded("c1")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "c1", output: "r")]
        )
        XCTAssertEqual(shape(result), ["system", "assistant(tool_calls)", "tool"])
        XCTAssertEqual(result[1].toolCalls.map(\.id), ["c1"])
        assertRoundsIntact(result)
    }

    func testApplyingLeavesAnEarlierUnrelatedAssistantAlone() {
        let result = ChatCompletionToolRoundTrip.applying(
            to: [
                ChatCompletionMessage(role: "system", content: "s"),
                ChatCompletionMessage(role: "user", content: "What is today's date?"),
                ChatCompletionMessage(role: "assistant", content: "Today is Friday."),
                ChatCompletionMessage(role: "user", content: "search Iron Heart"),
                ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
            ],
            functionCalls: [encoded("c1")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "c1", output: "r")]
        )
        XCTAssertEqual(shape(result), ["system", "user", "assistant", "user", "assistant(tool_calls)", "tool"])
        XCTAssertEqual(result[2].content, "Today is Friday.")
        assertRoundsIntact(result)
    }

    func testApplyingAttachesToTheRoundsOwnTextTurn() {
        let result = ChatCompletionToolRoundTrip.applying(
            to: [
                ChatCompletionMessage(role: "user", content: "search"),
                ChatCompletionMessage(role: "assistant", content: "Let me look that up."),
                ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
            ],
            functionCalls: [encoded("c1")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "c1", output: "r")]
        )
        XCTAssertEqual(shape(result), ["user", "assistant(tool_calls)", "tool"])
        XCTAssertEqual(result[1].content, "Let me look that up.")
    }

    func testApplyingPutsMissingResultsRightAfterTheirCall() {
        let result = ChatCompletionToolRoundTrip.applying(
            to: [
                ChatCompletionMessage(role: "system", content: "s"),
                ChatCompletionMessage(role: "user", content: "both"),
                ChatCompletionMessage(role: "tool", content: "A", toolCallID: "c1"),
            ],
            functionCalls: [encoded("c1"), encoded("c2", "fetch_page")],
            functionCallOutputs: [
                EncodedFunctionCallOutput(callID: "c1", output: "A"),
                EncodedFunctionCallOutput(callID: "c2", output: "B"),
            ]
        )
        XCTAssertEqual(shape(result), ["system", "user", "assistant(tool_calls)", "tool", "tool"])
        XCTAssertEqual(result.compactMap(\.toolCallID), ["c1", "c2"])
        assertRoundsIntact(result)
    }

    // MARK: Pre-send guard

    func testGuardMovesAMisplacedCallBeforeItsResult() {
        let broken = [
            ChatCompletionMessage(role: "system", content: "s"),
            ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("c1")]),
        ]
        XCTAssertNotNil(ToolRoundRequestGuard.problem(in: broken))
        let repaired = ToolRoundRequestGuard.repaired(broken)
        XCTAssertEqual(shape(repaired), ["system", "assistant(tool_calls)", "tool"])
        XCTAssertNil(ToolRoundRequestGuard.problem(in: repaired))
    }

    func testGuardDropsAnUnansweredTrailingCall() {
        let bare = ToolRoundRequestGuard.repaired([
            ChatCompletionMessage(role: "user", content: "search"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("c9")]),
        ])
        XCTAssertEqual(shape(bare), ["user"])
        let withText = ToolRoundRequestGuard.repaired([
            ChatCompletionMessage(role: "user", content: "search"),
            ChatCompletionMessage(role: "assistant", content: "Searching.", toolCalls: [call("c9")]),
        ])
        XCTAssertEqual(shape(withText), ["user", "assistant"])
        XCTAssertEqual(withText.last?.content, "Searching.")
    }

    func testGuardLeavesValidRequestsAlone() {
        let valid = [
            ChatCompletionMessage(role: "system", content: "s"),
            ChatCompletionMessage(role: "user", content: "search"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("c1")]),
            ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
        ]
        XCTAssertEqual(ToolRoundRequestGuard.repaired(valid), valid)
        XCTAssertNil(ToolRoundRequestGuard.problem(in: valid))
        let prefill = [
            ChatCompletionMessage(role: "user", content: "hi"),
            ChatCompletionMessage(role: "assistant", content: "Hel"),
        ]
        XCTAssertEqual(ToolRoundRequestGuard.repaired(prefill), prefill)
        XCTAssertNil(ToolRoundRequestGuard.problem(in: prefill))
    }

    func testGuardNamesTheProblem() throws {
        let message = try XCTUnwrap(ToolRoundRequestGuard.problem(in: [
            ChatCompletionMessage(role: "user", content: "search"),
            ChatCompletionMessage(role: "assistant", content: "", toolCalls: [call("c1")]),
        ]))
        XCTAssertTrue(message.contains("web_search"), message)
        XCTAssertTrue(message.contains("no result"), message)
    }

    func testResponsesGuardMovesCallBeforeOutputAndDropsTrailingCall() {
        let call = encoded("c1").functionCallItem!
        let output = EncodedFunctionCallOutput(callID: "c1", output: "r").item
        let user: [String: Any] = ["role": "user", "content": "search"]

        let moved = ToolRoundRequestGuard.repairedResponsesInput([user, output, call])
        XCTAssertEqual(moved.map { ($0["type"] as? String) ?? "message" }, ["message", "function_call", "function_call_output"])
        XCTAssertNil(ToolRoundRequestGuard.problem(inResponsesInput: moved))

        let trailing: [[String: Any]] = [user, call]
        XCTAssertNotNil(ToolRoundRequestGuard.problem(inResponsesInput: trailing))
        let dropped = ToolRoundRequestGuard.repairedResponsesInput(trailing)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?["role"] as? String, "user")

        // Chained requests only carry outputs; the stored response holds the calls.
        let chained = ToolRoundRequestGuard.repairedResponsesInput([output])
        XCTAssertEqual(chained.count, 1)
        XCTAssertNil(ToolRoundRequestGuard.problem(inResponsesInput: chained))
    }

    func testUnchainedResponsesPayloadKeepsEachCallBeforeItsOutput() {
        let payload = OpenAIRequestCodec.responsesPayload(
            model: "qwen/qwen3.8-27b",
            typedMessages: [
                ChatCompletionMessage(role: "system", content: "s"),
                ChatCompletionMessage(role: "tool", content: "r", toolCallID: "c1"),
            ],
            stream: true,
            functionCalls: [encoded("c1")],
            functionCallOutputs: [EncodedFunctionCallOutput(callID: "c1", output: "r")]
        )
        let input = payload["input"] as? [[String: Any]] ?? []
        XCTAssertEqual(input.map { ($0["type"] as? String) ?? "message" }, ["function_call", "function_call_output"])
        XCTAssertEqual(input.first?["call_id"] as? String, "c1")
    }
}
