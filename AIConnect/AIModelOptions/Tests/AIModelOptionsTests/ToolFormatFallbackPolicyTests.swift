// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ToolFormatFallbackPolicyTests: XCTestCase {
    func testGPTOSSDetection() {
        XCTAssertTrue(ToolFormatFallbackPolicy.looksLikeGPTOSS("openai/gpt-oss-120b"))
        XCTAssertTrue(ToolFormatFallbackPolicy.looksLikeGPTOSS("gpt-oss-20b"))
        XCTAssertFalse(ToolFormatFallbackPolicy.looksLikeGPTOSS("qwen3.8-27b"))
        XCTAssertFalse(ToolFormatFallbackPolicy.looksLikeGPTOSS("qwen3.8-flash-next"))
    }

    func testSuggestsWhenHarmonyForcedOnQwenOrTextLooksLikeAFailedCall() {
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "Sure, I'll edit the file.",
                forcedHarmonyOnNonGPTOSS: true
            )
        )
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "<|channel|>commentary to=functions.read_file <|message|>{}",
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertTrue(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: #"<tool_call>["name": broken]</tool_call>"#,
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertFalse(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 0,
                assistantText: "The function adds two numbers.",
                forcedHarmonyOnNonGPTOSS: false
            )
        )
        XCTAssertFalse(
            ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
                toolsWereOffered: true,
                parsedToolCallCount: 1,
                assistantText: "unused",
                forcedHarmonyOnNonGPTOSS: true
            )
        )
    }
}
