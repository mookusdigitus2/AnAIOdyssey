// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// PR #215 re-review: tail guard on pause, server-final drain, "no wait".
final class VoiceRereviewPolicyTests: XCTestCase {
    /// REQ-08 (blocker): a barge-in pause on an echo-cancelled route doesn't
    /// start the 0.6 s tail guard, so the user's next words reach the recognizer.
    /// Without echo cancellation (tap to interrupt) the room tail is still guarded.
    func testPauseStartsTheTailGuardOnlyWithoutEchoCancellation() {
        XCTAssertFalse(VoiceMicGate.pauseStartsTailGuard(echoCancelled: true))
        XCTAssertTrue(VoiceMicGate.pauseStartsTailGuard(echoCancelled: false))
    }

    /// REQ-07: the server's isFinal ends the reply as soon as playback drains.
    func testServerFinalEndsTheReplyOncePlaybackDrains() {
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 10.05, lastTextSentAt: 10, lastAudioAt: 10.02, playbackPending: false, serverFinal: true))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 10.05, lastTextSentAt: 10, lastAudioAt: nil, playbackPending: false, serverFinal: true))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 30, lastTextSentAt: 10, lastAudioAt: 10.02, playbackPending: true, serverFinal: true))
    }

    /// REQ-07: without isFinal, 0.8 s quiet is the fallback; no audio at all gives up after about 3 s.
    func testFallbacksWithoutServerFinal() {
        XCTAssertEqual(VoiceTTSDrainPolicy.quietAfterAudio, 0.8)
        XCTAssertEqual(VoiceTTSDrainPolicy.firstAudioTimeout, 3)
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 12.9, lastTextSentAt: 10, lastAudioAt: nil, playbackPending: false, serverFinal: false))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 13.1, lastTextSentAt: 10, lastAudioAt: nil, playbackPending: false, serverFinal: false))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: 10.5, lastTextSentAt: 10, lastAudioAt: 10.2, playbackPending: false, serverFinal: false))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 11.1, lastTextSentAt: 10, lastAudioAt: 10.2, playbackPending: false, serverFinal: false))
    }

    /// REQ-09: "no wait" and similar are a hold, not a new turn.
    func testNoPlusAHoldWordIsAHold() {
        for phrase in ["no wait", "No, wait!", "wait no", "no no wait", "nope hold on", "no hang on", "no one sec", "oh no wait"] {
            XCTAssertEqual(VoiceContinuePromptPolicy.classify(phrase), .hold, phrase)
        }
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("no stop"), .no)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("no"), .no)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("wait"), .hold)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("no wait what about tomorrow"), .other)
    }
}

/// B2 and B3 where ChatsView runs them: ChatsView keeps one
/// `VoiceReplySpeechOwner` and routes every speech side effect of a run through it.
@MainActor
final class VoiceReplySpeechOwnerTests: XCTestCase {
    private var live: Set<Int> = []
    private var owner: VoiceReplySpeechOwner!
    private var events: [String] = []

    override func setUp() async throws {
        live = [7]
        owner = VoiceReplySpeechOwner()
        events = []
    }

    private func isLive(_ session: Int) -> Bool { live.contains(session) }

    private func begin(_ turn: VoiceReplySpeechOwner.Turn, during: @escaping () -> Void = {}) async -> Bool {
        await owner.beginSpeech(
            for: turn,
            isSessionLive: isLive,
            prepare: { self.events.append("prepare"); during() },
            arm: { self.events.append("arm") },
            release: { self.events.append("release") }
        )
    }

    /// B2: Stop or Back during `prepareSpokenConversation` must not re-arm the mic.
    func testB2_SessionEndingDuringPrepareDoesNotArmAndReleasesAudio() async {
        let turn = owner.adopt(owner.nextTurn(voiceSession: 7))
        let armed = await begin(turn) { self.live.remove(7) }
        XCTAssertFalse(armed)
        XCTAssertEqual(events, ["prepare", "release"])
        XCTAssertFalse(owner.owns(turn, isSessionLive: isLive))
    }

    /// B2: a reply whose session already ended never prepares audio.
    func testB2_EndedSessionNeverPrepares() async {
        let turn = owner.adopt(owner.nextTurn(voiceSession: 7))
        live = []
        let armed = await begin(turn)
        XCTAssertFalse(armed)
        XCTAssertEqual(events, [])
    }

    /// The normal path arms speech after prepare.
    func testLiveTurnArms() async {
        let turn = owner.adopt(owner.nextTurn(voiceSession: 7))
        let armed = await begin(turn)
        XCTAssertTrue(armed)
        XCTAssertEqual(events, ["prepare", "arm"])
    }

    /// B3: a newer turn taking over during prepare: the old run neither arms
    /// nor releases (the audio now belongs to the new turn).
    func testB3_SupersededDuringPrepareLeavesTheNewTurnAlone() async {
        let first = owner.adopt(owner.nextTurn(voiceSession: 7))
        let armed = await begin(first) { _ = self.owner.adopt(self.owner.nextTurn(voiceSession: 7)) }
        XCTAssertFalse(armed)
        XCTAssertEqual(events, ["prepare"])
    }

    /// B3: an old run's cancel cleanup only touches its own turn.
    func testB3_OldRunCleanupDoesNotTouchTheNewReply() {
        let first = owner.adopt(owner.nextTurn(voiceSession: 7))
        let second = owner.adopt(owner.nextTurn(voiceSession: 7))
        owner.cleanUp(first) { events.append("cleanup first") }
        owner.cleanUp(second) { events.append("cleanup second") }
        XCTAssertEqual(events, ["cleanup second"])
        XCTAssertTrue(owner.isCurrent(second))
        XCTAssertFalse(owner.isCurrent(first))
    }

    /// B3: a turn refused before it was recorded never becomes current.
    func testNextTurnIsNotCurrentUntilAdopted() {
        let current = owner.adopt(owner.nextTurn(voiceSession: nil))
        let pending = owner.nextTurn(voiceSession: nil)
        XCTAssertTrue(owner.isCurrent(current))
        XCTAssertFalse(owner.isCurrent(pending))
        XCTAssertTrue(owner.owns(current, isSessionLive: isLive), "a typed turn has no voice session to end")
    }
}
