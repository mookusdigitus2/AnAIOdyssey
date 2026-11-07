// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceConnectionPolicyTests: XCTestCase {
    func testWarmsOnlyWhenVoiceOutputIsOn() {
        XCTAssertTrue(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .launchWithVoiceOn)
        )
        XCTAssertTrue(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .foregroundWithVoiceOn)
        )
        XCTAssertTrue(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .voiceToggledOn)
        )
        XCTAssertTrue(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .microphoneOpened)
        )
        XCTAssertFalse(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: false, trigger: .launchWithVoiceOn)
        )
        XCTAssertFalse(
            VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: false, trigger: .microphoneOpened)
        )
    }

    func testClosesOnToggleOffBackgroundAndIdle() {
        XCTAssertTrue(VoiceConnectionPolicy.shouldClose(voiceOutputEnabled: true, reason: .voiceToggledOff))
        XCTAssertTrue(VoiceConnectionPolicy.shouldClose(voiceOutputEnabled: false, reason: .voiceToggledOff))
        XCTAssertTrue(VoiceConnectionPolicy.shouldClose(voiceOutputEnabled: true, reason: .backgrounded))
        XCTAssertTrue(VoiceConnectionPolicy.shouldClose(voiceOutputEnabled: true, reason: .idleTimeout))
        XCTAssertTrue(VoiceConnectionPolicy.resetTurnCount(after: .idleTimeout))
    }

    func testFirstTurnThenSubsequentUntilReset() {
        XCTAssertEqual(VoiceConnectionPolicy.turnKind(completedSpokenTurns: 0), .first)
        XCTAssertEqual(VoiceConnectionPolicy.turnKind(completedSpokenTurns: 1), .subsequent)
        XCTAssertEqual(VoiceConnectionPolicy.turnKind(completedSpokenTurns: 4), .subsequent)
    }

    func testPreconnectHostsIncludeLLMAndActiveTTS() {
        let eleven = VoiceConnectionPolicy.hostsToPreconnect(
            llmBaseURL: "https://api.openai.com/v1",
            ttsProvider: .elevenLabs
        )
        XCTAssertEqual(
            Set(eleven.map(\.absoluteString)),
            ["https://api.openai.com/", "https://api.elevenlabs.io/"]
        )

        let openai = VoiceConnectionPolicy.hostsToPreconnect(
            llmBaseURL: "https://api.x.ai/v1",
            ttsProvider: .openai,
            openAIBaseURL: "https://api.openai.com/v1"
        )
        XCTAssertTrue(openai.contains { $0.host == "api.x.ai" })
        XCTAssertTrue(openai.contains { $0.host == "api.openai.com" })

        let system = VoiceConnectionPolicy.hostsToPreconnect(
            llmBaseURL: "https://api.openai.com/v1",
            ttsProvider: .system
        )
        XCTAssertEqual(system.map(\.host), ["api.openai.com"])
    }

    func testOriginURLNormalizesWebSocketAndPath() {
        XCTAssertEqual(
            VoiceConnectionPolicy.originURL(from: "wss://api.elevenlabs.io/v1/text-to-speech/abc/stream-input")?.absoluteString,
            "https://api.elevenlabs.io/"
        )
        XCTAssertEqual(
            VoiceConnectionPolicy.originURL(from: "https://api.x.ai/v1/tts")?.absoluteString,
            "https://api.x.ai/"
        )
        XCTAssertNil(VoiceConnectionPolicy.originURL(from: "  "))
        XCTAssertNil(VoiceConnectionPolicy.originURL(from: nil))
    }

    func testIdleTimeoutIsLongEnoughToSpanAPause() {
        XCTAssertGreaterThanOrEqual(VoiceConnectionPolicy.idleTimeoutSeconds, 60)
        XCTAssertLessThanOrEqual(VoiceConnectionPolicy.keepAliveIntervalSeconds, VoiceConnectionPolicy.idleTimeoutSeconds)
    }
}
