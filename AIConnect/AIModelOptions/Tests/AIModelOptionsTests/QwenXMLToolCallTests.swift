// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Qwen3.5 / 3.6 / 3.8 write tool calls as XML (Qwen3.8 chat template, tool section), and LM Studio
/// often leaves them in `content` or `reasoning_content` instead of `tool_calls`
/// (lmstudio-bug-tracker #2115, #1870, #825). Samples follow the template's exact layout.
final class QwenXMLToolCallTests: XCTestCase {
    static let reportReadySchema = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}"#

    /// The Settings tool test reply, left as text by LM Studio.
    static let reportReadyXML = """
    <tool_call>
    <function=report_ready>
    <parameter=ok>
    true
    </parameter>
    </function>
    </tool_call>
    """

    func testXMLCallInContent() throws {
        let calls = LMStudioToolProtocol.calls(inContent: Self.reportReadyXML, tools: ["report_ready": Self.reportReadySchema])
        XCTAssertEqual(calls.map(\.name), ["report_ready"])
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"ok":true}"#)
        XCTAssertEqual(calls.first?.id, "content-tool-1")
        XCTAssertEqual(LMStudioToolProtocol.prose(from: Self.reportReadyXML), "")
    }

    func testXMLCallAfterThinkingCloseTag() {
        // The template opens `<think>\n` itself, so the reply often has only the closing tag.
        let content = "The user wants me to call report_ready with ok=true.\n</think>\n\n" + Self.reportReadyXML
        let calls = LMStudioToolProtocol.calls(inContent: content, tools: ["report_ready": Self.reportReadySchema])
        XCTAssertEqual(calls.map(\.name), ["report_ready"])
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"ok":true}"#)
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking(content).trimmingCharacters(in: .whitespacesAndNewlines),
                       Self.reportReadyXML)
    }

    func testCallInsideThinkingIsNotContentButIsFoundInTheMessage() {
        let content = "<think>\nI should call the tool.\n" + Self.reportReadyXML + "\n</think>\n\n"
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: content).isEmpty,
                      "a call inside the thinking is not the answer when the answer is read alone")
        let message: [String: Any] = ["role": "assistant", "content": content]
        let calls = LMStudioToolProtocol.calls(in: message, tools: ["report_ready": Self.reportReadySchema])
        XCTAssertEqual(calls.map(\.name), ["report_ready"], "falls back to the thinking when the answer has no call")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"ok":true}"#)
    }

    func testCallInReasoningContent() {
        for key in ["reasoning_content", "reasoning"] {
            let message: [String: Any] = [
                "role": "assistant",
                "content": "",
                key: "The user wants report_ready.\n\n" + Self.reportReadyXML,
            ]
            let calls = LMStudioToolProtocol.calls(in: message, tools: ["report_ready": Self.reportReadySchema])
            XCTAssertEqual(calls.map(\.name), ["report_ready"], key)
            XCTAssertEqual(calls.first?.argumentsJSON, #"{"ok":true}"#, key)
        }
    }

    func testAnswerCallWinsOverThinkingCall() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": """
            <tool_call>
            <function=read_file>
            <parameter=path>
            a.swift
            </parameter>
            </function>
            </tool_call>
            """,
            "reasoning_content": "Maybe <tool_call>\n<function=build>\n</function>\n</tool_call> first?",
        ]
        XCTAssertEqual(LMStudioToolProtocol.calls(in: message).map(\.name), ["read_file"])
    }

    func testStructuredToolCallsStillWin() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": Self.reportReadyXML,
            "tool_calls": [["id": "7", "type": "function", "function": ["name": "build", "arguments": "{}"]]],
        ]
        XCTAssertEqual(LMStudioToolProtocol.calls(in: message).map(\.name), ["build"])
    }

    func testTypedParametersFollowTheSchema() throws {
        let schema = """
        {"type":"object","properties":{
          "path":{"type":"string"},"code":{"type":"string"},"line":{"type":"integer"},
          "ratio":{"type":"number"},"dry_run":{"type":"boolean"},"options":{"type":"object"},
          "tags":{"type":"array","items":{"type":"string"}},"limit":{"type":["integer","null"]}}}
        """
        let text = """
        <tool_call>
        <function=edit>
        <parameter=path>
        Sources/App.swift
        </parameter>
        <parameter=code>
        007
        </parameter>
        <parameter=line>
        42
        </parameter>
        <parameter=ratio>
        0.5
        </parameter>
        <parameter=dry_run>
        False
        </parameter>
        <parameter=options>
        {"force": true}
        </parameter>
        <parameter=tags>
        ["a", "b"]
        </parameter>
        <parameter=limit>
        3
        </parameter>
        <parameter=unknown>
        true
        </parameter>
        </function>
        </tool_call>
        """
        let call = try XCTUnwrap(LMStudioToolProtocol.calls(inContent: text, tools: ["edit": schema]).first)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["path"] as? String, "Sources/App.swift")
        XCTAssertEqual(args["code"] as? String, "007", "a string parameter stays a string")
        XCTAssertEqual(args["line"] as? Int, 42)
        XCTAssertEqual(args["ratio"] as? Double, 0.5)
        XCTAssertEqual(args["dry_run"] as? Bool, false)
        XCTAssertEqual((args["options"] as? [String: Any])?["force"] as? Bool, true)
        XCTAssertEqual(args["tags"] as? [String], ["a", "b"])
        XCTAssertEqual(args["limit"] as? Int, 3)
        XCTAssertEqual(args["unknown"] as? String, "true", "no schema: keep the text, don't guess")
        XCTAssertTrue(call.argumentsJSON.contains(#""code":"007""#), call.argumentsJSON)
    }

    func testWithoutSchemaEveryParameterIsText() {
        let call = LMStudioToolProtocol.calls(inContent: Self.reportReadyXML).first
        XCTAssertEqual(call?.argumentsJSON, #"{"ok":"true"}"#)
    }

    func testMultiLineStringParameter() throws {
        let text = """
        I'll write the file.

        <tool_call>
        <function=write_file>
        <parameter=path>
        README.md
        </parameter>
        <parameter=content>
        # Title

        This is the value
        that can span
        multiple lines
        </parameter>
        </function>
        </tool_call>
        """
        let schema = #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}"#
        let call = try XCTUnwrap(LMStudioToolProtocol.calls(inContent: text, tools: ["write_file": schema]).first)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["content"] as? String, "# Title\n\nThis is the value\nthat can span\nmultiple lines")
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), "I'll write the file.")
    }

    func testTwoCallsInOneReply() {
        // Template: later calls start on a new line after the previous `</tool_call>`.
        let text = """
        <tool_call>
        <function=read_file>
        <parameter=path>
        a.swift
        </parameter>
        </function>
        </tool_call>
        <tool_call>
        <function=git_status>
        </function>
        </tool_call>
        """
        let calls = LMStudioToolProtocol.calls(inContent: text)
        XCTAssertEqual(calls.map(\.name), ["read_file", "git_status"])
        XCTAssertEqual(calls.map(\.id), ["content-tool-1", "content-tool-2"])
        XCTAssertEqual(calls.last?.argumentsJSON, "{}")
    }

    func testBareFunctionBlockWithoutWrapper() {
        // Qwen3-Coder output left in content with no <tool_call> wrapper (lmstudio-bug-tracker #825).
        let text = "Running it.\n<function=build>\n<parameter=scheme>\nApp\n</parameter>\n</function>"
        let calls = LMStudioToolProtocol.calls(inContent: text)
        XCTAssertEqual(calls.map(\.name), ["build"])
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"scheme":"App"}"#)
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), "Running it.")
    }

    func testMalformedXMLStaysInProse() {
        let text = "<tool_call>\n<function=report_ready>\n<parameter=ok>\ntrue\n</tool_call>"
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: text).isEmpty)
        XCTAssertTrue(LMStudioToolProtocol.prose(from: text).contains("<function=report_ready>"))
        XCTAssertTrue(LMStudioToolProtocol.containsToolCallMarkup(LMStudioToolProtocol.prose(from: text)))
    }

    func testJSONAndXMLMixed() {
        let text = """
        <tool_call>
        {"name": "read_file", "arguments": {"path": "a"}}
        </tool_call>
        <tool_call>
        <function=build>
        </function>
        </tool_call>
        """
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: text).map(\.name), ["read_file", "build"])
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), "")
    }

    func testStrippingThinking() {
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking("a</think>b</think>\n\nAnswer"), "\n\nAnswer")
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking("Plain answer"), "Plain answer")
        XCTAssertEqual(LMStudioToolProtocol.strippingThinking("<think>\nstill thinking when it ran out"), "",
                       "an unclosed thinking block is all thinking")
        XCTAssertEqual(LMStudioToolProtocol.thinking(in: "<think>\nplan\n</think>\n\nAnswer"), "plan")
        XCTAssertEqual(LMStudioToolProtocol.thinking(in: "plan only\n</think>\nAnswer"), "plan only")
        XCTAssertNil(LMStudioToolProtocol.thinking(in: "Answer"))
    }

    func testProseLeavesThinkingTextForApps() {
        // Odyssey shows `<think>` sections itself, so prose only drops parsed calls from the answer.
        let text = "<think>\nplan\n</think>\nOn it.\n" + Self.reportReadyXML
        XCTAssertEqual(LMStudioToolProtocol.prose(from: text), "<think>\nplan\n</think>\nOn it.")
    }
}
