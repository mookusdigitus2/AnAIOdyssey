// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

final class HarmonyResponseCodecTests: XCTestCase {
    func testSanitizeStripsHarmonyTokensAndDuplicates() {
        let block = "Here are the events for tomorrow."
        let raw = "<|channel|>commentary to=list_calendar_events code<|message|>\(block)\(block)"
        let sanitized = HarmonyResponseCodec.sanitizeAssistantText(raw)
        XCTAssertFalse(sanitized.contains("<|channel|>"))
        XCTAssertFalse(sanitized.contains("to=list_calendar_events"))
        XCTAssertEqual(sanitized, block)
    }

    func testParseHarmonyToolCall() {
        let text = "<|channel|>commentary to=list_calendar_events code<|message|>30Hello"
        let blocks = HarmonyResponseCodec.parseHarmonyToolCalls(
            from: text,
            tags: ["list_calendar_events"]
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.toolType, "list_calendar_events")
    }

    func testParseHarmonyToolCallCapturesJSONArgs() {
        let text = #"<|channel|>commentary to=list_notes {"folder":"inbox"}"#
        let blocks = HarmonyResponseCodec.parseHarmonyToolCalls(
            from: text,
            tags: ["list_notes"]
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.toolType, "list_notes")
        XCTAssertEqual(blocks.first?.content, #"{"folder":"inbox"}"#)
    }

    // MARK: - Harmony spec conformance

    func testSanitizeShowsOnlyFinalChannelNeverAnalysis() {
        // The spec's own example: analysis (chain of thought) then final.
        let raw = "<|channel|>analysis<|message|>User asks simple addition. Answer directly.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>The result is 4.<|return|>"
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText(raw), "The result is 4.")
    }

    func testSanitizeStripsReturnAndConstrainTokens() {
        let raw = "<|channel|>final<|message|>Done.<|return|>"
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText(raw), "Done.")
    }

    func testSanitizeFallsBackToAnalysisWhenNoFinalExists() {
        // A truncated completion that never reached the final channel should
        // still show something rather than an empty reply.
        let raw = "<|channel|>analysis<|message|>Thinking about the request"
        XCTAssertEqual(
            HarmonyResponseCodec.sanitizeAssistantText(raw),
            "Thinking about the request"
        )
    }

    func testSanitizeDropsPartialTrailingControlToken() {
        let raw = "<|channel|>final<|message|>Streaming answer<|chan"
        XCTAssertEqual(HarmonyResponseCodec.sanitizeAssistantText(raw), "Streaming answer")
    }

    func testSanitizePassesPlainTextThrough() {
        XCTAssertEqual(
            HarmonyResponseCodec.sanitizeAssistantText("Just a normal reply."),
            "Just a normal reply."
        )
        XCTAssertEqual(
            HarmonyResponseCodec.sanitizeAssistantText("3D printing and 4K video"),
            "3D printing and 4K video"
        )
    }

    func testParseSpecShapedToolCallWithFunctionsNamespace() {
        // The canonical Harmony tool call: recipient in the header with the
        // functions. namespace, JSON arguments in the body, <|call|> terminator.
        let raw = "<|channel|>analysis<|message|>Need the weather.<|end|>"
            + "<|start|>assistant<|channel|>commentary to=functions.get_weather "
            + #"<|constrain|>json<|message|>{"location":"Paris"}<|call|>"#
        let blocks = HarmonyResponseCodec.parseHarmonyToolCalls(
            from: raw,
            tags: ["get_weather"]
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.toolType, "get_weather")
        XCTAssertEqual(blocks.first?.content, #"{"location":"Paris"}"#)
    }

    func testSanitizeExcludesToolCallArgumentsFromVisibleText() {
        let raw = "<|channel|>commentary<|message|>Checking the weather now.<|end|>"
            + "<|start|>assistant<|channel|>commentary to=functions.get_weather "
            + #"<|constrain|>json<|message|>{"location":"Paris"}<|call|>"#
        let sanitized = HarmonyResponseCodec.sanitizeAssistantText(raw)
        XCTAssertEqual(sanitized, "Checking the weather now.")
        XCTAssertFalse(sanitized.contains("location"))
    }

    func testParseMessagesSplitsChannelsAndRecipients() {
        let raw = "<|channel|>analysis<|message|>Think.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>Answer.<|return|>"
        let messages = HarmonyResponseCodec.parseMessages(raw)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.channel, "analysis")
        XCTAssertEqual(messages.first?.body, "Think.")
        XCTAssertEqual(messages.last?.channel, "final")
        XCTAssertEqual(messages.last?.body, "Answer.")
    }
}

@MainActor
final class RemoteConnectionTests: XCTestCase {
    func testReplacingModelsKeepsAvailableDefaultAndFallsBackWhenRemoved() {
        var connection = RemoteConnection(
            name: "Test",
            apiBaseURL: "http://localhost:1234/v1",
            defaultModel: "model-b",
            availableModels: ["old-model"]
        )

        connection.replaceAvailableModels(with: ["model-a", "model-b"])
        XCTAssertEqual(connection.defaultModel, "model-b")
        XCTAssertEqual(connection.availableModels, ["model-a", "model-b"])

        connection.replaceAvailableModels(with: ["model-c"])
        XCTAssertEqual(connection.defaultModel, "model-c")
        XCTAssertEqual(connection.availableModels, ["model-c"])
    }

    func testDefaultAndAvailableModelsPersistWithConnection() async throws {
        let suiteName = "RemoteConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ProviderSettings(defaults: defaults)
        settings.updateConnection(RemoteConnection(
            id: "persisted-remote",
            name: "Persisted",
            apiBaseURL: "http://localhost:1234/v1",
            defaultModel: "model-b",
            availableModels: ["model-a", "model-b"]
        ))
        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = ProviderSettings(defaults: defaults)
        let connection = try XCTUnwrap(restored.connection(id: "persisted-remote"))
        XCTAssertEqual(connection.defaultModel, "model-b")
        XCTAssertEqual(connection.availableModels, ["model-a", "model-b"])
    }

    func testSelectionKeyIncludesConnectionID() {
        let key = ConfiguredModelRegistry.selectionKey(
            modelID: "gpt-4o-mini",
            backend: .remote,
            connectionID: "conn-1"
        )
        XCTAssertEqual(key, "remote|conn-1|gpt-4o-mini")
    }

    func testParseSelectionKeyWithConnectionID() {
        let parsed = ConfiguredModelRegistry.parseSelectionKey("remote|conn-1|gpt-4o-mini")
        XCTAssertEqual(parsed?.modelID, "gpt-4o-mini")
        XCTAssertEqual(parsed?.backend, .remote)
        XCTAssertEqual(parsed?.connectionID, "conn-1")
    }
}
