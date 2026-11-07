// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class StreamTextCodecTests: XCTestCase {
    func testResponsesDeltasAppendAndDoneDoesNotDuplicate() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"type":"response.output_text.delta","delta":"I"}"#,
            #"{"type":"response.output_text.delta","delta":"'ll"}"#,
            #"{"type":"response.output_text.delta","delta":" research Scout's latest"}"#,
            #"{"type":"response.output_text.done","text":"I'll research Scout's latest"}"#,
            #"{"type":"response.completed","response":{"id":"resp_1","output_text":"I'll research Scout's latest"}}"#,
        ])
        XCTAssertEqual(final, "I'll research Scout's latest")
    }

    func testResponsesCumulativeDeltasAreTreatedAsSnapshots() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"type":"response.output_text.delta","delta":"I'll research Scout"}"#,
            #"{"type":"response.output_text.delta","delta":"I'll research Scout's latest"}"#,
        ])
        XCTAssertEqual(final, "I'll research Scout's latest")
    }

    func testResponsesOutputItemDoneDoesNotDuplicateDeltas() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"type":"response.output_text.delta","delta":"Hello"}"#,
            #"{"type":"response.output_text.delta","delta":" Astra"}"#,
            #"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Hello Astra"}]}}"#,
            #"{"type":"response.completed","response":{"output_text":"Hello Astra"}}"#,
        ])
        XCTAssertEqual(final, "Hello Astra")
    }

    func testResponsesCompletedAloneFillsEmptyAccumulator() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"type":"response.created","response":{"id":"resp_1"}}"#,
            #"{"type":"response.completed","response":{"id":"resp_1","output_text":"Saved report"}}"#,
        ])
        XCTAssertEqual(final, "Saved report")
    }

    func testChatCompletionsIncrementalDeltas() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"choices":[{"delta":{"content":"New "}}]}"#,
            #"{"choices":[{"delta":{"content":"Scout "}}]}"#,
            #"{"choices":[{"delta":{"content":"Vehicles"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ])
        XCTAssertEqual(final, "New Scout Vehicles")
    }

    func testChatCompletionsOllamaSnapshotsReplace() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"choices":[{"message":{"content":"I"}}]}"#,
            #"{"choices":[{"message":{"content":"I'll"}}]}"#,
            #"{"choices":[{"message":{"content":"I'll research Scout's latest"}}]}"#,
        ])
        XCTAssertEqual(final, "I'll research Scout's latest")
    }

    func testXAIChatCompletionsCumulativeDeltaField() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"choices":[{"delta":{"content":"I'll research Scout"}}]}"#,
            #"{"choices":[{"delta":{"content":"I'll research Scout's latest"}}]}"#,
        ])
        XCTAssertEqual(final, "I'll research Scout's latest")
    }

    func testChatCompletionsDeltaIsNotSnapshot() {
        let update = StreamTextCodec.classify(#"{"choices":[{"delta":{"content":"Hello"}}]}"#)
        XCTAssertEqual(update?.kind, .delta)
        XCTAssertEqual(update?.text, "Hello")
    }

    func testRepeatedTokenDeltasAppend() {
        var accumulator = StreamTextAccumulator()
        XCTAssertEqual(accumulator.apply(.delta("the")), "the")
        XCTAssertEqual(accumulator.apply(.delta(" the")), " the")
        XCTAssertEqual(accumulator.text, "the the")
        var again = StreamTextAccumulator()
        XCTAssertEqual(again.apply(.delta("the")), "the")
        XCTAssertEqual(again.apply(.delta("the")), "the")
        XCTAssertEqual(again.text, "thethe")
    }

    func testShortPrefixDeltaIsNotTreatedAsSnapshot() {
        var accumulator = StreamTextAccumulator()
        XCTAssertEqual(accumulator.apply(.delta("to")), "to")
        XCTAssertEqual(accumulator.apply(.delta("today")), "today")
        XCTAssertEqual(accumulator.text, "totoday")
    }

    func testWhitespaceOnlyDeltaAppends() {
        var accumulator = StreamTextAccumulator()
        XCTAssertEqual(accumulator.apply(.delta("Hello")), "Hello")
        XCTAssertEqual(accumulator.apply(.delta(" ")), " ")
        XCTAssertEqual(accumulator.apply(.delta("world")), "world")
        XCTAssertEqual(accumulator.text, "Hello world")
    }

    func testAnthropicTextDeltasThenStop() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Traveler"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":" and Terra"}}"#,
            #"{"type":"content_block_stop"}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(final, "Traveler and Terra")
    }

    func testMixedSSEPrefixAndDoneSnapshot() {
        let final = StreamTextCodec.apply(jsonLines: [
            #"data: {"type":"response.output_text.delta","delta":"Save "}"#,
            #"data: {"type":"response.output_text.delta","delta":"the document"}"#,
            #"data: {"type":"response.output_text.done","text":"Save the document"}"#,
            "data: [DONE]",
        ])
        XCTAssertEqual(final, "Save the document")
    }

    func testIncrementReturnedForUIMatchesFinalTextWhenAppended() {
        var accumulator = StreamTextAccumulator()
        var displayed = ""
        let lines = [
            #"{"type":"response.output_text.delta","delta":"I'll research Scout"}"#,
            #"{"type":"response.output_text.delta","delta":"I'll research Scout's latest"}"#,
            #"{"type":"response.output_text.done","text":"I'll research Scout's latest"}"#,
        ]
        for line in lines {
            displayed += accumulator.apply(json: line)
        }
        XCTAssertEqual(displayed, "I'll research Scout's latest")
        XCTAssertEqual(accumulator.text, displayed)
        XCTAssertFalse(displayed.contains("II'll"))
    }

    func testLMStudioSSEPlainContentIncrementalOrder() {
        var accumulator = StreamTextAccumulator()
        var emitted: [String] = []
        for line in LMStudioSSEFixtures.plainContent {
            guard let payload = StreamTextCodec.ssePayload(line) ?? (StreamTextCodec.isSSEDone(line) ? nil : nil) else {
                continue
            }
            if let increment = applyContent(payload, to: &accumulator), !increment.isEmpty {
                emitted.append(increment)
            }
        }
        XCTAssertEqual(emitted, ["Hel", "lo"])
        XCTAssertEqual(accumulator.text, "Hello")
    }

    func testLMStudioSSEReasoningThenContentOrder() {
        var content = StreamTextAccumulator()
        var reasoning = ""
        var emitted: [String] = []
        for line in LMStudioSSEFixtures.reasoningThenContent {
            guard let payload = StreamTextCodec.ssePayload(line) else { continue }
            if let thought = StreamTextCodec.classifyReasoning(payload) {
                reasoning += thought
                emitted.append("R:\(thought)")
            }
            if let increment = applyContent(payload, to: &content), !increment.isEmpty {
                emitted.append("C:\(increment)")
            }
        }
        XCTAssertEqual(emitted, ["R:think ", "R:step", "C:Hi"])
        XCTAssertEqual(reasoning, "think step")
        XCTAssertEqual(content.text, "Hi")
        XCTAssertNil(StreamTextCodec.classify(LMStudioSSEFixtures.reasoningOnlyChunk))
        XCTAssertEqual(
            StreamTextCodec.classifyReasoning(LMStudioSSEFixtures.reasoningOnlyChunk),
            "think "
        )
    }

    func testLMStudioSSEcrlfAndNoSpaceDataPrefix() {
        var accumulator = StreamTextAccumulator()
        var emitted: [String] = []
        for line in LMStudioSSEFixtures.crlfAndNoSpace {
            guard let payload = StreamTextCodec.ssePayload(line) else { continue }
            if let increment = applyContent(payload, to: &accumulator), !increment.isEmpty {
                emitted.append(increment)
            }
        }
        XCTAssertEqual(emitted, ["A", "B"])
        XCTAssertEqual(accumulator.text, "AB")
    }

    func testLMStudioSSEUsageOnlyFinalChunkEmitsNothing() {
        XCTAssertNil(StreamTextCodec.ssePayload(": keep-alive"))
        XCTAssertNil(StreamTextCodec.ssePayload("data: [DONE]"))
        XCTAssertTrue(StreamTextCodec.isSSEDone("data: [DONE]\r"))
        XCTAssertNil(StreamTextCodec.classify(LMStudioSSEFixtures.usageOnly))
        XCTAssertNil(StreamTextCodec.classifyReasoning(LMStudioSSEFixtures.usageOnly))
    }

    func testLMStudioToolCallFragmentsAccumulate() {
        var names: [Int: String] = [:]
        var arguments: [Int: String] = [:]
        for line in LMStudioSSEFixtures.toolCallFragments {
            guard let payload = StreamTextCodec.ssePayload(line) else { continue }
            for fragment in StreamTextCodec.toolCallFragments(payload) {
                if let name = fragment.name, !name.isEmpty {
                    names[fragment.index] = name
                }
                arguments[fragment.index, default: ""] += fragment.arguments
            }
        }
        XCTAssertEqual(names[0], "web_search")
        XCTAssertEqual(arguments[0], #"{"query":"news"}"#)
        XCTAssertNil(StreamTextCodec.classify(LMStudioSSEFixtures.toolCallFragments[0]))
    }

    private func applyContent(_ payload: String, to accumulator: inout StreamTextAccumulator) -> String? {
        guard let update = StreamTextCodec.classify(payload) else { return nil }
        return accumulator.apply(update)
    }

    func testClassifyIgnoresToolAndHeartbeatEvents() {
        XCTAssertNil(StreamTextCodec.classify(#"{"type":"response.created","response":{"id":"r"}}"#))
        XCTAssertNil(StreamTextCodec.classify(#"{"type":"response.function_call_arguments.delta","delta":"{"}"#))
        XCTAssertNil(StreamTextCodec.classify("data: [DONE]"))
    }
}

/// Captured-style LM Studio OpenAI-compat SSE (`POST /v1/chat/completions`).
enum LMStudioSSEFixtures {
    /// Incremental `delta.content` only.
    static let plainContent = [
        #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
        "data: [DONE]",
    ]

    /// Developer reasoning on, then the visible reply. `reasoning_content`
    /// is LM Studio 0.3.9+; `reasoning` is 0.3.23+ gpt-oss.
    static let reasoningThenContent = [
        #"data: {"choices":[{"delta":{"reasoning_content":"think "}}]}"#,
        #"data: {"choices":[{"delta":{"reasoning":"step"}}]}"#,
        #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#,
        "data: [DONE]",
    ]

    static let reasoningOnlyChunk =
        #"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#

    /// `data:` with no space and `\r` endings (`bytes.lines` keeps `\r`).
    static let crlfAndNoSpace = [
        "data:{\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\r",
        "data: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}\r",
        "data: [DONE]\r",
    ]

    static let usageOnly =
        #"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#

    static let toolCallFragments = [
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"web_search","arguments":""}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"news\"}"}}]}}]}"#,
    ]
}
