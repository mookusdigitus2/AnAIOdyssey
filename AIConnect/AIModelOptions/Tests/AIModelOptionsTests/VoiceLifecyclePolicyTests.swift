// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceLifecyclePolicyTests: XCTestCase {
    func testViewRebuildDoesNotTeardownVoice() {
        XCTAssertFalse(VoiceLifecyclePolicy.shouldTeardownConversation(reason: .viewDisappear))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldTeardownConversation(reason: .sizeClassChange))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldCancelSpeech(reason: .viewDisappear))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldTeardownConversation(reason: .sceneBackground))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldTeardownConversation(reason: .userExitedVoice))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldTeardownConversation(reason: .userLeftChat))
    }

    func testBackgroundPausesListeningAndKeepsSpeech() {
        XCTAssertTrue(VoiceLifecyclePolicy.shouldPauseListening(reason: .sceneBackground))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldPauseListening(reason: .sceneInactive))
        XCTAssertTrue(
            VoiceLifecyclePolicy.shouldResumeListening(
                reason: .sceneForeground,
                voiceControlArmed: true
            )
        )
        XCTAssertTrue(
            VoiceLifecyclePolicy.shouldResumeListening(
                reason: .interruptionEndedShouldResume,
                voiceControlArmed: true
            )
        )
        XCTAssertFalse(
            VoiceLifecyclePolicy.shouldResumeListening(
                reason: .sceneForeground,
                voiceControlArmed: false
            )
        )
        XCTAssertTrue(VoiceLifecyclePolicy.shouldKeepSpeakingInBackground(audioBackgroundModeEnabled: true))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldKeepSpeakingInBackground(audioBackgroundModeEnabled: false))
    }

    func testHFPAndCarAudioSkipVoiceProcessing() {
        XCTAssertFalse(VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: .bluetoothHFP))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: .speaker))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldEnableVoiceProcessing(route: .headphones))
        XCTAssertFalse(
            VoiceEchoPolicy.shouldEnableAcousticEchoCancellation(
                route: .bluetoothHFP,
                voiceProcessingAvailable: true
            )
        )
        XCTAssertEqual(
            VoiceEchoPolicy.routeKind(outputPortTypes: ["CarAudio"]),
            .bluetoothHFP
        )
    }

    func testZeroFormatDoesNotInstallTapOrStartEngine() {
        let zero = VoiceHardwareFormat(sampleRate: 0, channelCount: 0, route: .bluetoothHFP)
        XCTAssertFalse(VoiceLifecyclePolicy.shouldInstallTap(format: zero))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldInstallTap(format: nil))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldInstallTap(format: .hfp16kMono))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldStartEngine(formatValid: false, routeSettled: true))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldStartEngine(formatValid: true, routeSettled: false))
        XCTAssertTrue(VoiceLifecyclePolicy.shouldStartEngine(formatValid: true, routeSettled: true))
    }

    func testSessionMustStopEngineAndMustNotForceHFPRates() {
        XCTAssertFalse(VoiceLifecyclePolicy.shouldActivateSessionWhileEngineRunning())
        XCTAssertFalse(VoiceLifecyclePolicy.allowsForcedSampleRate())
        XCTAssertFalse(VoiceLifecyclePolicy.allowsForcedIOBufferDuration())
        XCTAssertTrue(VoiceLifecyclePolicy.observerCallbackMustHopToMainActor())
        XCTAssertEqual(VoiceLifecyclePolicy.routeSettleMilliseconds, 250)
    }

    func testDebugLogKeepsLastTwoHundredEvents() {
        let events = VoiceAudioDebugLogPolicy.append(
            Array(repeating: "x", count: 200),
            event: "newest"
        )
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(events.last, "newest")
        XCTAssertEqual(
            VoiceAudioBreadcrumb(timestamp: "t", event: "route", detail: "HFP").line,
            "t route HFP"
        )
    }
}

/// #176 + #178: a reply that keeps generating after Back must not keep
/// feeding TTS (that restarted audio after the user left).
final class VoiceBackgroundReplySpeechTests: XCTestCase {
    func testReplyStopsSpeakingOnceChatIsOffScreen() {
        XCTAssertTrue(VoiceLifecyclePolicy.shouldKeepSpeakingReply(speechEnabled: true, chatOnScreen: true))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldKeepSpeakingReply(speechEnabled: true, chatOnScreen: false))
        XCTAssertFalse(VoiceLifecyclePolicy.shouldKeepSpeakingReply(speechEnabled: false, chatOnScreen: true))
    }
}
