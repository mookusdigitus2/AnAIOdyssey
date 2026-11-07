// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// PR #219 re-review probes (E, F and B1 edges), kept as permanent tests.
final class QwenReReviewEdgeTests: XCTestCase {
    static let call = "<tool_call>\n<function=git_status>\n</function>\n</tool_call>"
    static let tools = ["git_status": #"{"type":"object","properties":{}}"#, "read_file": #"{"type":"object","properties":{"path":{"type":"string"}}}"#]

    /// E1: `<think>` lines shown in a code block are part of the answer.
    func testE1_ThinkTagsInsideACodeBlockStayInTheAnswer() {
        let answer = "Strip the tags like this:\n```\n<think>\nreasoning\n</think>\n```\nThen parse the rest."
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking(answer), answer)
        XCTAssertNil(LMStudioToolProtocol.thinking(in: answer))
    }

    /// E2: a reply led by `<think>` whose answer mentions `</think>` inline splits at the thinking's own close.
    func testE2_ThinkLedReplyMentioningTheTagKeepsTheAnswer() {
        let content = "<think>\nplan\n</think>\n\nThe tag </think> ends thinking."
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking(content).trimmingCharacters(in: .whitespacesAndNewlines),
                       "The tag </think> ends thinking.")
        XCTAssertEqual(LMStudioToolProtocol.thinking(in: content), "plan")
    }

    /// E4: Qwen's usual close-only thinking still splits.
    func testE4_QwenCloseOnlyThinking() {
        let content = "plan the edit\n</think>\n\nDone, README updated."
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking(content).trimmingCharacters(in: .whitespacesAndNewlines),
                       "Done, README updated.")
        XCTAssertEqual(LMStudioToolProtocol.thinking(in: content), "plan the edit")
    }

    /// F1: a stray unclosed ``` before a real call doesn't swallow it.
    func testF1_UnclosedFenceBeforeARealCall() {
        let text = "Run ``` to start a block.\n" + Self.call
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: text).map(\.name), ["git_status"])
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), "Run ``` to start a block.")
    }

    /// F2: an inline ``` pair closed before the call doesn't block it.
    func testF2_ClosedInlineFenceBeforeACall() {
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: "Use ```code``` style.\n" + Self.call).map(\.name), ["git_status"])
    }

    /// F4: a fence inside a parameter value is kept intact.
    func testF4_FenceInsideAParameterValue() throws {
        let text = "<tool_call>\n<function=write_file>\n<parameter=path>\nREADME.md\n</parameter>\n<parameter=content>\n# T\n```swift\nlet x = 1\n```\n</parameter>\n</function>\n</tool_call>"
        let call = try XCTUnwrap(LMStudioToolProtocol.calls(inContent: text).first)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["content"] as? String, "# T\n```swift\nlet x = 1\n```")
    }

    /// F5: a fenced example followed by a real call runs only the real call.
    func testF5_FencedExampleThenRealCall() {
        let text = "Format:\n```\n<function=x>\n</function>\n```\n" + Self.call
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: text).map(\.name), ["git_status"])
    }

    /// F6: an unclosed ``` earlier in the thinking doesn't hide the call there.
    func testF6_UnclosedFenceInThinking() {
        let message: [String: Any] = ["role": "assistant", "content": "", "reasoning_content": "I'll write ``` later.\n" + Self.call]
        XCTAssertEqual(LMStudioToolProtocol.calls(in: message, tools: Self.tools).map(\.name), ["git_status"])
    }

    /// B1a/B1c/B1d: last thinking call only; whitespace answer counts as empty; nothing without tools.
    func testB1Edges() {
        let two = "First:\n<tool_call>\n<function=read_file>\n<parameter=path>\na\n</parameter>\n</function>\n</tool_call>\nthen\n" + Self.call
        XCTAssertEqual(LMStudioToolProtocol.calls(in: ["content": "", "reasoning_content": two], tools: Self.tools).map(\.name), ["git_status"])
        XCTAssertEqual(LMStudioToolProtocol.calls(in: ["content": "\n\n", "reasoning_content": Self.call], tools: Self.tools).map(\.name), ["git_status"])
        XCTAssertTrue(LMStudioToolProtocol.calls(in: ["content": "", "reasoning_content": Self.call]).isEmpty)
    }
}
