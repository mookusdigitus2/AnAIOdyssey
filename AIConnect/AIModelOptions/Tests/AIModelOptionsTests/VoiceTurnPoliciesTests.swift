// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceTurnPoliciesTests: XCTestCase {
    func testBargeInNeedsTwoWords() {
        XCTAssertFalse(VoiceBargeInPolicy.shouldPause(heard: ""))
        XCTAssertFalse(VoiceBargeInPolicy.shouldPause(heard: "wait"))
        XCTAssertTrue(VoiceBargeInPolicy.shouldPause(heard: "hold on"))
    }

    func testRecoveryBacksOffAndCaps() {
        XCTAssertEqual(VoiceRecoveryPolicy.retryDelay(afterFailures: 1), 0)
        XCTAssertEqual(VoiceRecoveryPolicy.retryDelay(afterFailures: 2), 0.25)
        XCTAssertEqual(VoiceRecoveryPolicy.retryDelay(afterFailures: 3), 0.5)
        XCTAssertEqual(VoiceRecoveryPolicy.retryDelay(afterFailures: 10), 2)
        XCTAssertFalse(VoiceRecoveryPolicy.shouldGiveUp(afterFailures: VoiceRecoveryPolicy.maxConsecutiveFailures - 1))
        XCTAssertTrue(VoiceRecoveryPolicy.shouldGiveUp(afterFailures: VoiceRecoveryPolicy.maxConsecutiveFailures))
    }

    func testTTSDrainWaitsForAudioOnTheWire() {
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 10.1, lastTextSentAt: 10, lastAudioAt: nil, playbackPending: false))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 10.5, lastTextSentAt: 10, lastAudioAt: 10.2, playbackPending: false))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 11.1, lastTextSentAt: 10, lastAudioAt: 10.2, playbackPending: false))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 20, lastTextSentAt: 10, lastAudioAt: 10.2, playbackPending: true))
    }

    func testEchoCheckFailures() {
        let ok = VoiceEchoCheck(voiceProcessingExpected: true, voiceProcessingOn: true, playerOnSameEngine: true, sessionIsVoiceChat: true)
        XCTAssertTrue(ok.passes)
        XCTAssertTrue(ok.echoCancelled)
        let bad = VoiceEchoCheck(voiceProcessingExpected: true, voiceProcessingOn: false, playerOnSameEngine: false, sessionIsVoiceChat: false)
        XCTAssertEqual(bad.failures, ["voiceProcessing=off", "player=detached", "mode!=voiceChat"])
        XCTAssertFalse(bad.echoCancelled)
    }

    func testListeningNeverHearsAPlayingReply() {
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .listening, replyPlaying: true, echoCancelled: true, roomTailQuiet: true))
        XCTAssertTrue(VoiceListenGate.feedsRecognizer(mode: .watchingForBargeIn, replyPlaying: true, echoCancelled: true, roomTailQuiet: true))
    }

    func testHoldPhrases() {
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("hold on"), .hold)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("um, wait"), .hold)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("hang on please"), .hold)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("go on"), .yes)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("wait, what's that"), .other)
    }

    func testSubmittedIDsAreBounded() async {
        await MainActor.run {
            let submitter = ChatTurnSubmitter(runs: BackgroundRunCenter())
            for id in 1...(ChatTurnSubmitter.rememberedUtterances * 2) {
                submitter.submit(chatID: "c", text: "t", utteranceID: id, execution: .cloud, record: {}) { _ in }
            }
            XCTAssertEqual(submitter.rememberedUtteranceCount, ChatTurnSubmitter.rememberedUtterances)
        }
    }
}
