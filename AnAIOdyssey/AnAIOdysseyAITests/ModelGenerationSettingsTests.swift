// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

final class ModelGenerationOptionsPayloadTests: XCTestCase {
    func testReasoningEffortAppliedToReasoningModels() {
        var payload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-5.6-sol",
            messages: [["role": "user", "content": "hi"]],
            stream: true
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high),
            to: &payload,
            model: "gpt-5.6-sol"
        )
        XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
    }

    func testReasoningEffortSkippedForClassicModels() {
        var payload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-4o",
            messages: [["role": "user", "content": "hi"]],
            stream: true
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .low),
            to: &payload,
            model: "gpt-4o"
        )
        XCTAssertNil(payload["reasoning_effort"])
    }

    func testMaxTokensOverrideUsesModelFamilyField() {
        // Reasoning family: overrides max_completion_tokens, never max_tokens.
        var reasoningPayload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-5.6-luna",
            messages: [],
            stream: true
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(maxOutputTokens: 32_000),
            to: &reasoningPayload,
            model: "gpt-5.6-luna"
        )
        XCTAssertEqual(reasoningPayload["max_completion_tokens"] as? Int, 32_000)
        XCTAssertNil(reasoningPayload["max_tokens"])

        // Classic family: overrides max_tokens.
        var classicPayload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-4o",
            messages: [],
            stream: true
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(maxOutputTokens: 2048),
            to: &classicPayload,
            model: "gpt-4o"
        )
        XCTAssertEqual(classicPayload["max_tokens"] as? Int, 2048)
    }

    func testEmptyOptionsLeavePayloadUntouched() {
        var payload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-5.6-sol",
            messages: [],
            stream: true
        )
        let before = payload.keys.sorted()
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(),
            to: &payload,
            model: "gpt-5.6-sol"
        )
        XCTAssertEqual(payload.keys.sorted(), before)
        XCTAssertNil(payload["reasoning_effort"])
    }

    func testAnthropicMaxTokensOverride() {
        var payload = OpenAICompatibleAPI.anthropicMessagesPayload(
            model: "claude-sonnet-4-5",
            messages: [["role": "user", "content": "hi"]],
            stream: false
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .high, maxOutputTokens: 8192),
            to: &payload,
            model: "claude-sonnet-4-5"
        )
        XCTAssertEqual(payload["max_tokens"] as? Int, 8192)
        XCTAssertNil(payload["reasoning_effort"], "Anthropic models must not receive reasoning_effort")
    }

    func testAstraDefaultsToMediumAndNeverSendsMinimal() {
        var payload = OpenAICompatibleAPI.chatPayload(
            model: "gpt-6-astra",
            messages: [["role": "user", "content": "hi"]],
            stream: true
        )
        OpenAICompatibleAPI.applyGenerationOptions(
            ModelGenerationOptions(reasoningEffort: .minimal),
            to: &payload,
            model: "gpt-6-astra"
        )
        XCTAssertEqual(payload["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(payload["max_completion_tokens"] as? Int, 128_000)
        XCTAssertTrue(OpenAICompatibleAPI.supportsReasoningEffort("gpt-6-astra"))
    }
}

final class ModelGenerationSettingsStoreTests: XCTestCase {
    private let connectionID = "test-connection-\(UUID().uuidString)"

    override func tearDown() {
        ModelGenerationSettings.removeOptions(connectionID: connectionID)
        super.tearDown()
    }

    func testRoundTripAndRemoval() {
        let options = ModelGenerationOptions(reasoningEffort: .medium, maxOutputTokens: 16_000)
        ModelGenerationSettings.setOptions(options, connectionID: connectionID, modelID: "gpt-5.6-sol")

        let loaded = ModelGenerationSettings.options(connectionID: connectionID, modelID: "gpt-5.6-sol")
        XCTAssertEqual(loaded, options)

        // A different model on the same connection is untouched.
        XCTAssertTrue(
            ModelGenerationSettings.options(connectionID: connectionID, modelID: "gpt-4o").isEmpty
        )

        ModelGenerationSettings.removeOptions(connectionID: connectionID)
        XCTAssertTrue(
            ModelGenerationSettings.options(connectionID: connectionID, modelID: "gpt-5.6-sol").isEmpty
        )
    }

    func testClearingOptionsRemovesEntry() {
        ModelGenerationSettings.setOptions(
            ModelGenerationOptions(reasoningEffort: .high),
            connectionID: connectionID,
            modelID: "o3-mini"
        )
        ModelGenerationSettings.setOptions(
            ModelGenerationOptions(),
            connectionID: connectionID,
            modelID: "o3-mini"
        )
        XCTAssertTrue(
            ModelGenerationSettings.options(connectionID: connectionID, modelID: "o3-mini").isEmpty
        )
    }
}
