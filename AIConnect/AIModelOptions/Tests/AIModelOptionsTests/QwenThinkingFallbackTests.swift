// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// PR #219 review (B1, N1, N2): a call is read from the thinking only when the model gave no
/// answer, only for an offered tool, from one thinking source, and only the last one. Example
/// calls in a code block don't run, and a `</think>` mentioned in an answer isn't thinking.
final class QwenThinkingFallbackTests: XCTestCase {
    static let schema = #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}"#
    static let tools = ["write_file": schema, "read_file": schema, "report_ready": #"{"type":"object","properties":{"ok":{"type":"boolean"}}}"#]

    static func call(_ name: String, path: String) -> String {
        "<tool_call>\n<function=\(name)>\n<parameter=path>\n\(path)\n</parameter>\n</function>\n</tool_call>"
    }

    /// P1: a drafted call in the thinking doesn't run when the model answered in prose.
    func testDraftCallInThinkingIsIgnoredWhenThereIsAnAnswer() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "I've looked at it; no change is needed. README.md is fine as is.",
            "reasoning_content": "Maybe I should overwrite it:\n" + Self.call("write_file", path: "README.md") + "\nActually no, it's fine.",
        ]
        XCTAssertTrue(LMStudioToolProtocol.calls(in: message, tools: Self.tools).isEmpty)
    }

    /// P2: the template's own example (`example_function_name`) is not an offered tool.
    func testThinkingCallMustNameAnOfferedTool() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "",
            "reasoning_content": "The format is " + Self.call("example_function_name", path: "x") + " but no tool is needed.",
        ]
        XCTAssertTrue(LMStudioToolProtocol.calls(in: message, tools: Self.tools).isEmpty)
        XCTAssertTrue(LMStudioToolProtocol.calls(in: message).isEmpty, "with no tools offered nothing in the thinking runs")
    }

    /// P3: the same call in a `<think>` block and in `reasoning_content` runs once.
    func testOneThinkingSourceNoDoubleCount() {
        let xml = Self.call("report_ready", path: "x")
        let message: [String: Any] = [
            "role": "assistant",
            "content": "<think>\nCall it.\n\(xml)\n</think>\n\n",
            "reasoning_content": "Call it.\n\(xml)",
        ]
        XCTAssertEqual(LMStudioToolProtocol.calls(in: message, tools: Self.tools).map(\.name), ["report_ready"])
    }

    func testOnlyTheLastThinkingCallRuns() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "",
            "reasoning_content": "First " + Self.call("write_file", path: "a") + " no, better: " + Self.call("read_file", path: "b"),
        ]
        let calls = LMStudioToolProtocol.calls(in: message, tools: Self.tools)
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"path":"b"}"#)
    }

    /// P4 (N2): an answer that shows the format in a code block doesn't run it.
    func testCallInsideACodeFenceDoesNotRun() {
        let text = "Qwen's format looks like this:\n```\n<tool_call>\n<function=git_status>\n</function>\n</tool_call>\n```\nThat's all."
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: text).isEmpty)
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), text)
        let jsonFence = "```xml\n<tool_call>\n{\"name\": \"build\", \"arguments\": {}}\n</tool_call>\n```"
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: jsonFence).isEmpty)
        // A real call after the fence still runs.
        let after = text + "\n" + Self.call("read_file", path: "a")
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: after).map(\.name), ["read_file"])
    }

    /// P5 (N1): a `</think>` mentioned inside an answer is not the end of thinking.
    func testThinkTagMentionedInAnAnswerIsKept() {
        let answer = "The parser drops everything up to the last </think> tag, then reads the rest."
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking(answer), answer)
        XCTAssertNil(LMStudioToolProtocol.thinking(in: answer))
        XCTAssertEqual(LMStudioToolProtocol.prose(from: answer), answer)
        // The real shapes still split: closing tag on its own line, or a reply that opens with <think>.
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking("plan\n</think>\n\nAnswer"), "\n\nAnswer")
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking("<think>short</think>Answer"), "Answer")
    }
}
