// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Qwen3.8's chat template accepts only `xhigh` (default), `medium` and `low`; any other
/// `reasoning_effort` raises "Unexpected reasoning effort" (HTTP 500 on llama.cpp).
final class QwenReasoningEffortTests: XCTestCase {
    func testQwen38OffersOnlyTheTemplatesLevels() {
        for id in ["qwen/qwen3.8-27b", "qwen3.8-27b-mlx-4bit", "Qwen/Qwen3.8-27B"] {
            let caps = ModelCapabilityCatalog.capabilities(forModelID: id, backend: .remote)
            XCTAssertEqual(caps.supportedReasoningEfforts, [.low, .medium, .xhigh], id)
            XCTAssertNil(caps.defaultReasoningEffort, "the server applies the model's own default")
            XCTAssertFalse(caps.alwaysSendsReasoningEffort)
            XCTAssertEqual(caps.contextWindowTokens, 262_144)
        }
    }

    func testLMStudioListIsIntersectedNotCopiedForQwen38() {
        let live = LiveModelCapabilities(reasoningEfforts: [.low, .medium, .high], defaultReasoningEffort: .high)
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "qwen/qwen3.8-27b", backend: .remote, live: live)
        XCTAssertEqual(caps.supportedReasoningEfforts, [.low, .medium])
        XCTAssertNil(caps.defaultReasoningEffort, "high is not a level this template takes")
        XCTAssertNil(ModelCapabilityCatalog.sanitizedReasoningEffort(.high, capabilities: caps))
        XCTAssertEqual(ModelCapabilityCatalog.sanitizedReasoningEffort(.low, capabilities: caps), .low)
    }

    func testOtherModelsStillTakeLMStudiosList() {
        let live = LiveModelCapabilities(reasoningEfforts: [.low, .high], defaultReasoningEffort: .high)
        let caps = ModelCapabilityCatalog.capabilities(forModelID: "openai/gpt-oss-20b", backend: .remote, live: live)
        XCTAssertEqual(caps.supportedReasoningEfforts, [.low, .high])
        XCTAssertEqual(caps.defaultReasoningEffort, .high)
    }
}
