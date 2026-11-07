// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Fixtures copied from LM Studio's tool-use and list-models docs.
final class LMStudioToolProtocolTests: XCTestCase {
    func testV1Types() {
        XCTAssertEqual(LMStudioToolProtocol.supportsTools(in: ["type": "llm", "capabilities": ["trained_for_tool_use": false]]), true)
        XCTAssertEqual(LMStudioToolProtocol.supportsTools(in: ["type": "vlm", "capabilities": [String]()]), true)
        XCTAssertEqual(LMStudioToolProtocol.supportsTools(in: ["type": "embedding"]), false)
        XCTAssertEqual(LMStudioToolProtocol.supportsTools(in: ["type": "embeddings"]), false)
        XCTAssertEqual(LMStudioToolProtocol.supportsTools(in: ["type": "decision"]), false)
        XCTAssertNil(LMStudioToolProtocol.supportsTools(in: ["id": "plain"]))
    }

    func testCurlToolCallAndContentFallbacks() {
        let message: [String: Any] = [
            "role": "assistant",
            "tool_calls": [[
                "id": "365174485",
                "type": "function",
                "function": [
                    "name": "search_products",
                    "arguments": "{\"query\":\"dell\",\"category\":\"electronics\",\"max_price\":50}",
                ],
            ]],
        ]
        let parsed = LMStudioToolProtocol.calls(in: message)
        XCTAssertEqual(parsed.map(\.name), ["search_products"])
        XCTAssertEqual(parsed.first?.id, "365174485")
        XCTAssertEqual(parsed.first?.argumentsJSON, #"{"query":"dell","category":"electronics","max_price":50}"#)

        let qwen = """
        <tool_call>
        {"name": "get_delivery_date", "arguments": {"order_id": "123"}}
        </tool_call>
        """
        let qwenCalls = LMStudioToolProtocol.calls(inContent: qwen)
        XCTAssertEqual(qwenCalls.map(\.name), ["get_delivery_date"])
        XCTAssertEqual(qwenCalls.first?.argumentsJSON, #"{"order_id":"123"}"#)
        XCTAssertEqual(LMStudioToolProtocol.prose(from: qwen), "")

        let two = """
        [TOOL_REQUEST]{"name": "send_email", "arguments": {"to": "John", "subject": "meeting"}}[END_TOOL_REQUEST]
        [TOOL_REQUEST]{"name": "open_browser", "arguments": {}}[END_TOOL_REQUEST]
        """
        XCTAssertEqual(LMStudioToolProtocol.calls(inContent: two).map(\.name), ["send_email", "open_browser"])

        let malformed = """
        <tool_call>
        ["name": "get_delivery_date", function: "date"]
        </tool_call>
        """
        XCTAssertTrue(LMStudioToolProtocol.calls(inContent: malformed).isEmpty)
        XCTAssertTrue(LMStudioToolProtocol.prose(from: malformed).contains("function"))
    }

    func testAliasIDsIncludeVariantAndLoadedInstance() {
        let row: [String: Any] = [
            "key": "google/gemma-4-26b-a4b",
            "selected_variant": "google/gemma-4-26b-a4b@q4_k_m",
            "variants": ["google/gemma-4-26b-a4b@q4_k_m"],
            "loaded_instances": [["id": "google/gemma-4-26b-a4b"]],
        ]
        XCTAssertEqual(
            LMStudioToolProtocol.aliasIDs(in: row),
            ["google/gemma-4-26b-a4b", "google/gemma-4-26b-a4b@q4_k_m"]
        )
    }
}
