// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class LMStudioModelRecordTests: XCTestCase {
    func testLoadedInstanceContextWinsOverMax() {
        let row: [String: Any] = [
            "key": "qwen3.8-flash-next",
            "type": "llm",
            "max_context_length": 131_072,
            "loaded_instances": [[
                "id": "qwen3.8-flash-next",
                "config": ["context_length": 8192],
            ]],
            "capabilities": [
                "vision": false,
                "trained_for_tool_use": true,
                "reasoning": [
                    "allowed_options": ["low", "medium", "high"],
                    "default": "medium",
                ],
            ],
        ]
        XCTAssertEqual(LMStudioModelRecord.contextLength(in: row), 8192)
        XCTAssertEqual(LMStudioModelRecord.supportsVision(in: row), false)
        XCTAssertEqual(LMStudioModelRecord.reasoningEfforts(in: row), [.low, .medium, .high])
        XCTAssertEqual(LMStudioModelRecord.defaultReasoningEffort(in: row), .medium)
    }

    func testUnloadedModelUsesMaxContextLength() {
        let row: [String: Any] = [
            "key": "gemma-4",
            "type": "vlm",
            "max_context_length": 32_768,
            "capabilities": ["vision": true],
        ]
        XCTAssertEqual(LMStudioModelRecord.contextLength(in: row), 32_768)
        XCTAssertEqual(LMStudioModelRecord.supportsVision(in: row), true)
        XCTAssertTrue(LMStudioModelRecord.reasoningEfforts(in: row).isEmpty)
    }

    func testParseModelsListKeepsContextVisionAndReasoning() throws {
        let json = """
        {"models":[{
          "key":"qwen3.8-flash-next","type":"llm","max_context_length":131072,
          "loaded_instances":[{"id":"qwen3.8-flash-next","config":{"context_length":4096}}],
          "capabilities":{"vision":false,"trained_for_tool_use":false,
            "reasoning":{"allowed_options":["low","high"],"default":"low"}}
        }]}
        """
        let models = try OpenAIRequestCodec.parseModelsList(Data(json.utf8))
        XCTAssertEqual(models.first?.id, "qwen3.8-flash-next")
        XCTAssertEqual(models.first?.contextWindowTokens, 4096)
        XCTAssertEqual(models.first?.supportsVision, false)
        XCTAssertEqual(models.first?.supportsTools, true)
        XCTAssertEqual(models.first?.reasoningEfforts, [.low, .high])
        XCTAssertEqual(models.first?.defaultReasoningEffort, .low)
    }

    func testLiveCapabilitiesOverrideStaticCatalogContext() {
        let live = LiveModelCapabilities(
            contextWindowTokens: 8192,
            supportsVision: true,
            reasoningEfforts: [.low, .medium],
            defaultReasoningEffort: .low
        )
        let caps = ModelCapabilityCatalog.capabilities(
            forModelID: "house-qwen",
            backend: .remote,
            live: live
        )
        XCTAssertEqual(caps.contextWindowTokens, 8192)
        XCTAssertTrue(caps.supportsVision)
        XCTAssertEqual(caps.supportedReasoningEfforts, [.low, .medium])
        XCTAssertEqual(caps.defaultReasoningEffort, .low)
        XCTAssertTrue(caps.supportsThinking)
    }

    func testChatCompletionsSendsLMStudioThinkingLevel() {
        let live = LiveModelCapabilities(
            reasoningEfforts: [.low, .medium, .high],
            defaultReasoningEffort: .medium
        )
        var payload: [String: Any] = ["model": "qwen3.8-flash-next", "stream": true]
        // Qwen3.8's template takes only low, medium and xhigh, so pick one it accepts.
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .low),
            to: &payload,
            model: "qwen3.8-flash-next",
            api: .chatCompletions,
            live: live
        )
        XCTAssertEqual(payload["reasoning_effort"] as? String, "low")
        XCTAssertEqual((payload["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testResponsesSendsLMStudioThinkingLevel() {
        let live = LiveModelCapabilities(
            reasoningEfforts: [.low, .medium],
            defaultReasoningEffort: .low
        )
        var payload: [String: Any] = ["model": "openai/gpt-oss-20b"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .low),
            to: &payload,
            model: "openai/gpt-oss-20b",
            api: .responses,
            live: live
        )
        XCTAssertEqual((payload["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(payload["reasoning_effort"])
    }

    func testThinkingLevelOmittedWithoutLiveOrCatalogSupport() {
        var payload: [String: Any] = ["model": "house-qwen"]
        OpenAIRequestCodec.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high),
            to: &payload,
            model: "house-qwen",
            api: .chatCompletions
        )
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertNil(payload["reasoning"])
    }
}
