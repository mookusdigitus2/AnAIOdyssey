// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Requirement tests on the shared harness (VoiceRequirementHarness.swift).
/// Each test names its requirement ID from VOICE_MODE_REQUIREMENTS.md.
@MainActor
final class VoiceRequirementHarnessTests: XCTestCase {
    private var h: VoiceHarness!

    override func setUp() async throws {
        h = VoiceHarness()
        await h.start()
        XCTAssertEqual(h.controller.state, .listening)
    }

    override func tearDown() async throws {
        await h.stop()
        h = nil
    }

    private func turnWithPlayingReply(_ text: String = "tell me a story") {
        h.say(text)
        h.replyStartsPlaying()
        XCTAssertEqual(h.controller.state, .speaking)
    }

    // MARK: REQ-02 One owner

    /// REQ-02: one live pass at a time; results from any older pass are ignored.
    func testREQ02_OnlyTheLivePassReports() {
        h.partial("what's the")
        let first = try! XCTUnwrap(h.livePass)
        h.speech.restartRecognizerForTesting()
        let second = try! XCTUnwrap(h.livePass)
        XCTAssertNotEqual(first, second)
        h.late(pass: first, "something else entirely", final: false)
        h.late(pass: first, "something else entirely")
        h.partial("weather")
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["what's the weather"])
    }

    // MARK: REQ-03 One submit point

    /// REQ-03: spoken turns go through the same submit point as typed ones.
    func testREQ03_SpokenAndTypedShareTheSubmitPoint() {
        let typed = h.submitter.submit(chatID: "chat", text: "typed", utteranceID: nil, execution: .cloud, record: {}) { _ in }
        XCTAssertTrue(typed)
        h.say("spoken")
        XCTAssertEqual(h.offered.map(\.text), ["spoken"])
        XCTAssertEqual(h.turns.map(\.text), ["spoken"])
        let replay = h.submitter.submit(chatID: "chat", text: "spoken", utteranceID: h.turns[0].id, execution: .cloud, record: {}) { _ in }
        XCTAssertFalse(replay, "the same utterance id never submits twice")
    }

    // MARK: REQ-04 One debounce

    /// REQ-04: 1.5 s of silence (no new words, no voice) submits; less does not.
    func testREQ04_OnlyFullSilenceSubmits() {
        h.partial("what's the weather")
        h.silence(1.4)
        XCTAssertTrue(h.turns.isEmpty)
        h.micBuffer(.user, words: "what's the weather") // still talking, same words
        h.silence(1.4)
        XCTAssertTrue(h.turns.isEmpty, "voice resets the debounce")
        h.partial("what's the weather in Paris")
        h.silence(1.4)
        XCTAssertTrue(h.turns.isEmpty, "new words reset the debounce")
        h.silence(0.1)
        XCTAssertEqual(h.turns.map(\.text), ["what's the weather in Paris"])
    }

    /// REQ-04: a final result is not an endpoint; only the debounce submits.
    func testREQ04_FinalResultDoesNotSubmit() {
        h.final("hello there")
        XCTAssertTrue(h.turns.isEmpty)
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["hello there"])
    }

    // MARK: REQ-05 Exactly once

    /// REQ-05 (N2): the submitted-id memory is bounded and still dedupes recent ids.
    func testREQ05_SubmittedIDsAreBounded() {
        let submitter = ChatTurnSubmitter(runs: BackgroundRunCenter())
        for id in 1...(ChatTurnSubmitter.rememberedUtterances + 50) {
            XCTAssertTrue(submitter.submit(chatID: "c", text: "t\(id)", utteranceID: id, execution: .cloud, record: {}) { _ in })
        }
        XCTAssertEqual(submitter.rememberedUtteranceCount, ChatTurnSubmitter.rememberedUtterances)
        let recent = ChatTurnSubmitter.rememberedUtterances + 50
        XCTAssertFalse(submitter.submit(chatID: "c", text: "again", utteranceID: recent, execution: .cloud, record: {}) { _ in })
    }

    /// REQ-05: old text is never re-delivered after an error restart.
    func testREQ05_ErrorRestartDoesNotReplayText() {
        h.say("first")
        h.replyRunEnds()
        h.partial("second")
        h.fail()
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["first", "second"])
    }

    // MARK: REQ-07 Turn-taking

    /// REQ-07: listening resumes only when playback actually finishes. The
    /// run ending while audio still plays keeps the session speaking.
    func testREQ07_ListeningWaitsForPlaybackToDrain() async {
        turnWithPlayingReply()
        h.replyRunEnds()
        await h.settle()
        XCTAssertEqual(h.controller.state, .speaking, "audio is still playing")
        XCTAssertNotEqual(h.speech.mode, .listening)
        h.playback.drain()
        await h.settle()
        XCTAssertEqual(h.controller.state, .listening)
        XCTAssertEqual(h.speech.mode, .listening)
    }

    /// REQ-07: the build-38 order of events. The run ended before the first
    /// reply audio played (thinking -> listening), then the audio played.
    func testREQ07_RunEndingBeforeAudioStillWaitsForIt() async {
        h.say("tell me a story")
        h.playback.startReply() // audio playing, run about to end
        h.replyRunEnds()
        await h.settle()
        XCTAssertEqual(h.controller.state, .speaking)
        h.playback.drain()
        await h.settle()
        XCTAssertEqual(h.controller.state, .listening)
    }

    /// REQ-07 (N3): a turn the submit point refuses returns the session to listening.
    func testREQ07_RefusedTurnReturnsToListening() {
        h.submitAccepts = false
        h.say("hello")
        XCTAssertEqual(h.offered.count, 1)
        XCTAssertEqual(h.controller.state, .listening)
        XCTAssertEqual(h.speech.mode, .listening)
        h.submitAccepts = true
        h.say("hello again")
        XCTAssertEqual(h.turns.map(\.text), ["hello again"])
    }

    // MARK: REQ-08 Barge-in

    /// REQ-08: barge-in pauses (keeps the rest), shows the prompt, listens, never submits.
    func testREQ08_BargeInPausesAndNeverSubmits() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "wait stop")
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue)
        XCTAssertEqual(h.playback.events, ["play", "pause"])
        XCTAssertTrue(h.playback.queued, "the rest of the reply is kept")
        XCTAssertEqual(h.speech.mode, .listening)
        XCTAssertEqual(h.turns.count, 1)
    }

    /// REQ-08 (B1): what barged in is carried into the answer the debounce submits.
    func testREQ08_BargeInWordsAreKept() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "what about")
        h.micBuffer(.user, words: "what about tomorrow")
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["tell me a story", "what about tomorrow"])
        XCTAssertEqual(h.playback.events, ["play", "pause", "discard"])
    }

    /// REQ-08 (re-review blocker): a buffer 0.1 s after the barge-in pause
    /// reaches the recognizer, and those words are part of the answer.
    func testREQ08_SpeechRightAfterTheBargeInPauseIsHeard() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "what about")
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue)
        h.clock.advance(0.1)
        XCTAssertTrue(h.micBuffer(.user, words: "what about tomorrow"), "fed 0.1 s after the pause")
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["tell me a story", "what about tomorrow"])
    }

    /// REQ-09: the run ended while paused; "yes" resumes the rest and the
    /// session listens again once that audio drains (no stuck .speaking).
    func testREQ09_YesAfterTheRunEndedWhilePausedDrainsThenListens() async {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "hold on")
        h.silence()
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue)
        h.replyRunEnds()
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue, "audio left: still waiting on the answer")
        h.say("yes")
        XCTAssertEqual(h.controller.state, .speaking)
        XCTAssertTrue(h.playback.isPlaying)
        await h.settle()
        XCTAssertEqual(h.controller.state, .speaking, "still playing")
        h.playback.drain()
        await h.settle()
        XCTAssertEqual(h.controller.state, .listening)
    }

    /// REQ-09: "no wait" holds; the prompt stays up and the reply isn't dropped.
    func testREQ09_NoWaitHolds() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "no wait")
        h.silence()
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue)
        XCTAssertEqual(h.turns.count, 1, "not a new turn")
        XCTAssertFalse(h.playback.events.contains("discard"))
    }

    /// REQ-08 (N7): fewer than two words never barge in.
    func testREQ08_OneWordIsNotABargeIn() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "hmm")
        h.silence()
        XCTAssertEqual(h.controller.state, .speaking)
        XCTAssertEqual(h.playback.events, ["play"])
    }

    // MARK: REQ-09 Continue prompt

    /// REQ-09: a pure hold phrase keeps the prompt; a later yes still answers it.
    func testREQ09_HoldPhraseKeepsThePromptThenYesResumes() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "hold on")
        h.silence()
        XCTAssertEqual(h.controller.state, .pausedAwaitingContinue, "hold stays paused")
        XCTAssertTrue(h.playback.queued, "the reply is not dropped")
        XCTAssertEqual(h.turns.count, 1, "hold is not a turn")
        XCTAssertEqual(h.speech.mode, .listening)
        h.say("yes")
        XCTAssertEqual(h.controller.state, .speaking)
        XCTAssertEqual(h.playback.events, ["play", "pause", "resume"])
    }

    /// REQ-09: after a hold, no ends the reply.
    func testREQ09_HoldThenNoEnds() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "one sec")
        h.silence()
        h.say("no")
        XCTAssertEqual(h.controller.state, .listening)
        XCTAssertEqual(h.discarded, 1)
        XCTAssertEqual(h.turns.count, 1)
    }

    /// REQ-09: anything else becomes the new turn and drops the reply.
    func testREQ09_OtherBecomesTheTurn() {
        turnWithPlayingReply()
        h.micBuffer(.user, words: "hang on")
        h.silence()
        h.say("what's the capital of France")
        XCTAssertEqual(h.turns.map(\.text), ["tell me a story", "what's the capital of France"])
        XCTAssertFalse(h.playback.queued)
        XCTAssertEqual(h.controller.state, .thinking)
    }

    /// REQ-09: the hold phrases live in one constant and classify as hold;
    /// yes, no and other are unchanged.
    func testREQ09_HoldPhraseList() {
        for phrase in ["hold on", "wait", "pause", "one sec", "hang on", "Hold on, please", "wait a second"] {
            XCTAssertEqual(VoiceContinuePromptPolicy.classify(phrase), .hold, phrase)
        }
        XCTAssertTrue(VoiceContinuePromptPolicy.holdPhrases.contains("hold on"))
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("yes"), .yes)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("keep going"), .yes)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("no"), .no)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("stop"), .no)
        XCTAssertEqual(VoiceContinuePromptPolicy.classify("wait what about Paris"), .other)
    }

    // MARK: REQ-10 Echo by playback state

    /// REQ-10: without echo cancellation (HFP) the mic is off during playback; taps interrupt.
    func testREQ10_HFPKeepsTheMicOffDuringPlayback() {
        h.route = .bluetoothHFP
        turnWithPlayingReply()
        XCTAssertEqual(h.speech.mode, .off)
        XCTAssertFalse(h.micBuffer(.user, words: "stop stop"))
        XCTAssertFalse(h.micBuffer(.reply, words: "once upon a time"))
        XCTAssertEqual(h.controller.state, .speaking)
        XCTAssertEqual(h.turns.count, 1)
    }

    /// REQ-10: the room tail right after playback is not fed to the recognizer.
    func testREQ10_RoomTailIsIgnored() async {
        turnWithPlayingReply()
        h.playback.drain()
        h.replyRunEnds()
        await h.settle()
        XCTAssertEqual(h.speech.mode, .listening)
        XCTAssertFalse(h.micBuffer(.reply, words: "the end"), "within 0.6 s of playback")
        h.clock.advance(VoiceMicGate.tailGuardSeconds)
        XCTAssertTrue(h.micBuffer(.user, words: "next question"))
    }

    // MARK: REQ-11 Stop and Back

    /// REQ-11 (N5): Stop during Thinking is instant, and the reply's late
    /// events don't re-arm anything.
    func testREQ11_StopDuringThinking() async {
        h.say("tell me a story")
        XCTAssertEqual(h.controller.state, .thinking)
        let token = try! XCTUnwrap(h.controller.sessionToken)
        h.controller.stop()
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertFalse(h.controller.isLive(sessionToken: token), "the reply may not speak")
        h.replyStartsPlaying()
        h.replyRunEnds()
        await h.controller.waitUntilSettled()
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.speech.mode, .off)
    }

    /// REQ-11 (B2): Back, backgrounding and an interruption all end the
    /// session token captured at submit, even after a new session starts.
    func testREQ11_SessionEndInvalidatesTheReplysToken() async {
        for end in ["leave", "background", "interruption"] {
            await h.start()
            h.say("question for \(end)")
            let token = try! XCTUnwrap(h.controller.sessionToken)
            XCTAssertTrue(h.controller.isLive(sessionToken: token))
            switch end {
            case "leave": h.controller.leave()
            case "background": h.controller.enterBackground()
            default: h.controller.handleInterruption(began: true, shouldResume: false)
            }
            XCTAssertFalse(h.controller.isLive(sessionToken: token), end)
            await h.controller.waitUntilSettled()
            await h.start()
            XCTAssertFalse(h.controller.isLive(sessionToken: token), "\(end): a new session is not the reply's")
            await h.stop()
        }
    }

    // MARK: REQ-12 Recovery

    /// REQ-12 (B4): repeated recognizer errors back off, then stop with a
    /// user-visible error instead of looping.
    func testREQ12_ErrorLoopBacksOffThenStops() async {
        h.fail()
        XCTAssertNotNil(h.livePass, "the first retry is immediate")
        h.fail()
        XCTAssertNil(h.livePass, "the second one backs off")
        XCTAssertTrue(h.speech.isBackingOffForTesting)
        h.silence(VoiceRecoveryPolicy.retryDelay(afterFailures: 2) + 0.05)
        XCTAssertNotNil(h.livePass)
        for failures in 3...VoiceRecoveryPolicy.maxConsecutiveFailures {
            h.fail()
            if failures < VoiceRecoveryPolicy.maxConsecutiveFailures {
                h.silence(VoiceRecoveryPolicy.retryDelay(afterFailures: failures) + 0.05)
            }
        }
        XCTAssertEqual(h.controller.state, .error(VoiceRecoveryPolicy.failureMessage))
        XCTAssertEqual(h.failures, [VoiceRecoveryPolicy.failureMessage])
        XCTAssertEqual(h.speech.mode, .off)
        await h.controller.waitUntilSettled()
    }

    /// REQ-12: heard words reset the failure count; a long-lived pass that
    /// fails is not part of a loop.
    func testREQ12_ProgressResetsTheRetryCount() {
        h.fail()
        h.fail()
        h.silence(0.3)
        XCTAssertEqual(h.speech.consecutiveFailuresForTesting, 2)
        h.silence(VoiceRecoveryPolicy.healthyPassSeconds)
        h.fail()
        XCTAssertEqual(h.speech.consecutiveFailuresForTesting, 1, "a pass that lived 10 s is not a loop")
        h.fail()
        h.silence(0.3)
        h.partial("hello")
        XCTAssertEqual(h.speech.consecutiveFailuresForTesting, 0, "heard words reset the count")
    }

    /// REQ-12 (N5): Apple ending the live pass with isFinal (no error)
    /// restarts it; the words lead the new pass and submit once.
    func testREQ12_LiveFinalRestartsThePass() {
        h.partial("what's the")
        let pass = try! XCTUnwrap(h.livePass)
        h.final("what's the")
        let next = try! XCTUnwrap(h.livePass, "never silently deaf")
        XCTAssertNotEqual(next, pass)
        h.partial("weather")
        h.silence()
        XCTAssertEqual(h.turns.map(\.text), ["what's the weather"])
    }

    // MARK: REQ-13 Logging

    /// REQ-13 (N4): state and turn logs carry the utterance and pass ids;
    /// refusals are logged.
    func testREQ13_LogsCarryUtteranceAndPassIDs() {
        let log = VoiceLogCapture()
        defer { log.stop() }
        h.say("hello")
        h.replyRunEnds()
        h.submitAccepts = false
        h.say("refused one")
        let shape = try! NSRegularExpression(pattern: "utt=\\d+ pass=(\\d+|-)")
        let lines = log.lines("voice.session.state") + log.lines("voice.session.turn")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertNotNil(shape.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
        XCTAssertEqual(log.lines("voice.session.turn.refused").count, 1)
    }
}
