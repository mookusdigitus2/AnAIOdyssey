// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// PR #219 third review: an unclosed fence inside close-only thinking (T1/T2), and a draft shown
/// after an opening fence that never closes (T7), kept as permanent tests.
final class QwenReview3Tests: XCTestCase {
    static let call = "<tool_call>\n<function=git_status>\n</function>\n</tool_call>"
    static let draft = "<tool_call>\n<function=write_file>\n<parameter=path>\nREADME.md\n</parameter>\n<parameter=content>\n# draft\n</parameter>\n</function>\n</tool_call>"
    static let tools = ["git_status": #"{"type":"object","properties":{}}"#,
                        "write_file": #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}"#]

    private func answer(_ text: String) -> String {
        LMStudioToolProtocol.strippingThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// T1: Qwen3.5+ close-only thinking with an unclosed ``` and a rejected write_file draft.
    func testT1_UnclosedFenceInCloseOnlyThinkingDoesNotRunTheDraft() {
        let content = "Maybe write:\n```markdown\n" + Self.draft + "\nActually no, it's fine.\n</think>\n\nREADME.md is fine as is."
        XCTAssertTrue(LMStudioToolProtocol.calls(in: ["role": "assistant", "content": content], tools: Self.tools).isEmpty)
        XCTAssertEqual(answer(content), "README.md is fine as is.")
        XCTAssertTrue(LMStudioToolProtocol.thinking(in: content)?.hasPrefix("Maybe write:") == true)
    }

    /// T2: the same shape without a call: the thinking doesn't leak into the answer.
    func testT2_UnclosedFenceInCloseOnlyThinkingStaysThinking() {
        let content = "Plan: use\n```\nthen answer.\n</think>\n\nDone."
        XCTAssertEqual(answer(content), "Done.")
        XCTAssertTrue(LMStudioToolProtocol.thinking(in: content)?.contains("then answer.") == true)
    }

    /// T3: a think-led reply with an unclosed fence still splits.
    func testT3_UnclosedFenceInThinkLedReply() {
        let content = "<think>\nPlan:\n```\n" + Self.draft + "\nno.\n</think>\n\nREADME.md is fine."
        XCTAssertTrue(LMStudioToolProtocol.calls(in: ["content": content], tools: Self.tools).isEmpty)
        XCTAssertEqual(answer(content), "README.md is fine.")
    }

    /// T4–T6: balanced fences in thinking, a call after the close, and the first line-ending close.
    func testT4ToT6_StillSplitAsBefore() {
        XCTAssertEqual(answer("Code:\n```swift\nlet x = 1\n```\n</think>\n\nDone."), "Done.")
        XCTAssertEqual(LMStudioToolProtocol.calls(in: ["content": "plan\n</think>\n\nRunning it.\n" + Self.call], tools: Self.tools).map(\.name),
                       ["git_status"])
        XCTAssertEqual(answer("plan\n</think>\n\nTo end thinking, emit:\n</think>\nas its own line."),
                       "To end thinking, emit:\n</think>\nas its own line.")
    }

    /// T7: a draft after an opening fence line that never closes (cut off at max tokens) is an example.
    func testT7_DraftAfterUnclosedOpeningFenceLineDoesNotRun() {
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: "Here is what I'd write if needed:\n```\n" + Self.draft).isEmpty)
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: "Example:\n  ```xml\n" + Self.draft).isEmpty, "indented fence line")
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: "```\n" + Self.draft).isEmpty, "fence at the very start")
        XCTAssertTrue(LMStudioToolProtocol.calls(in: ["content": "", "reasoning_content": "Draft:\n```\n" + Self.draft], tools: Self.tools).isEmpty)
    }

    /// F1/F6 still hold: a ``` mentioned mid-line is a stray marker, not a code block.
    func testInlineStrayFenceStillDoesNotSwallowTheCall() {
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: "Run ``` to start a block.\n" + Self.call).map(\.name), ["git_status"])
        XCTAssertEqual(LMStudioToolProtocol.calls(in: ["content": "", "reasoning_content": "I'll write ``` later.\n" + Self.call],
                                                  tools: Self.tools).map(\.name), ["git_status"])
        XCTAssertEqual(LMStudioToolProtocol.prose(from: "Here:\n```\n" + Self.draft), "Here:\n```\n" + Self.draft)
    }
}
