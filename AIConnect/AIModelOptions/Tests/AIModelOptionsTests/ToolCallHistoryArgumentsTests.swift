// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Regression: a follow-up after `current_date` got LM Studio's HTML
/// "Internal Server Error". The server parses every history `function.arguments` as JSON
/// (llama.cpp `func_args_not_string`), so a turn must never carry "" or plain text there.
final class ToolCallHistoryArgumentsTests: XCTestCase {
    private func arguments(_ call: ChatCompletionToolCall) -> String? {
        (call.jsonObject["function"] as? [String: Any])?["arguments"] as? String
    }

    private func jsonObject(_ text: String?) -> [String: Any]? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testEmptyArgumentsGoBackAsAnEmptyObject() {
        XCTAssertEqual(arguments(ChatCompletionToolCall(id: "call_1", name: "current_date", arguments: "")), "{}")
        XCTAssertEqual(arguments(ChatCompletionToolCall(id: "call_1", name: "current_date", arguments: "  \n")), "{}")
    }

    func testValidJSONArgumentsAreSentUnchanged() {
        let raw = #"{"query":"weather in Paris","count":3}"#
        XCTAssertEqual(arguments(ChatCompletionToolCall(id: "call_1", name: "web_search", arguments: raw)), raw)
        XCTAssertEqual(arguments(ChatCompletionToolCall(id: "call_1", name: "current_date", arguments: "{}")), "{}")
    }

    func testPlainTextArgumentsAreWrappedAsJSON() {
        let sent = jsonObject(arguments(ChatCompletionToolCall(id: "call_1", name: "web_search", arguments: "weather in Paris")))
        XCTAssertEqual(sent?["input"] as? String, "weather in Paris")
        let truncated = jsonObject(arguments(ChatCompletionToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"wea"#)))
        XCTAssertNotNil(truncated, "a cut-off JSON object still goes back as valid JSON")
    }

    func testResponsesFunctionCallItemAlsoCarriesJSON() {
        let item = EncodedFunctionCall(name: "current_date", arguments: "", callID: "call_1").functionCallItem
        XCTAssertEqual(item?["arguments"] as? String, "{}")
    }
}
