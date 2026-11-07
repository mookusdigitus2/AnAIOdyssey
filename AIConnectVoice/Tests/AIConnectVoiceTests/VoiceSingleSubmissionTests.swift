// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Pipeline whose listening is the real `SystemSpeechInputService`, running
/// without the microphone or Apple's recognizer: tests feed it recognizer
/// results the way `SFSpeechRecognitionTask` would. Playback is recorded.
@MainActor
final class RecognizerBackedPipeline: VoicePipelineBackend {
    let speech = SystemSpeechInputService(hardwareFreeForTesting: true)
    var events: [String] = []
    /// Speaker with echo cancellation, or headphones. False models HFP.
    var bargeInAvailable = true
    var replyAudioLeft = true

    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        try await speech.beginContinuousListening(onEvent: onEvent)
    }
    func setListenMode(_ mode: VoiceListenMode) { speech.setMode(mode) }
    func silenceImmediately() { speech.setMode(.off) }
    func teardownPipeline() async { speech.endContinuousListening() }
    var micLevel: Double { 0 }
    var hasLiveAudio: Bool { false }
    var speechBargeInAvailable: Bool { bargeInAvailable }
    func pauseReplyPlayback() { events.append("pause") }
    func resumeReplyPlayback() { events.append("resume") }
    func discardReplyPlayback() { events.append("discard"); replyAudioLeft = false }
    var hasReplyAudioLeft: Bool { replyAudioLeft }

    var livePass: Int? { speech.livePassIDForTesting }

    /// The recognizer revising the live pass's transcript.
    func hear(_ text: String, final: Bool = false) {
        guard let pass = livePass else { return }
        speech.receiveRecognitionForTesting(pass: pass, text: text, isFinal: final)
    }

    /// 1.5 s of silence.
    func endpoint() { speech.endpointForTesting() }
}

/// One test (or more) per requirement in AnAIOdyssey/docs/VOICE_MODE_REQUIREMENTS.md.
@MainActor
final class VoiceModeRequirementsTests: XCTestCase {
    private var pipeline: RecognizerBackedPipeline!
    private var controller: VoiceSessionController!
    private var turns: [VoiceUtterance] = []
    private var discarded = 0

    override func setUp() async throws {
        pipeline = RecognizerBackedPipeline()
        controller = VoiceSessionController(backend: pipeline)
        controller.onFailure = { _, _ in }
        turns = []
        discarded = 0
        controller.onTurn = { [unowned self] in self.turns.append($0); return true }
        controller.onReplyDiscarded = { [unowned self] in self.discarded += 1 }
        controller.start()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(pipeline.speech.mode, .listening)
    }

    override func tearDown() async throws {
        controller.stop()
        await controller.waitUntilSettled()
    }

    private func say(_ text: String) {
        pipeline.hear(text)
        pipeline.endpoint()
    }

    /// A spoken turn whose reply is now playing.
    private func turnWithPlayingReply(_ text: String = "tell me a story") {
        say(text)
        controller.replyStarted()
        XCTAssertEqual(controller.state, .speaking)
    }

    // MARK: 3, 4, 5 — one submit point, one debounce, exactly once

    /// REQ-03 REQ-04 REQ-05
    func testOneSubmitPerUtterance() {
        pipeline.hear("what's")
        pipeline.hear("what's the weather")
        pipeline.hear("what's the weather", final: true)
        XCTAssertTrue(turns.isEmpty, "partials and finals never submit; only the 1.5 s debounce does")

        pipeline.endpoint()
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["what's the weather"])
        XCTAssertEqual(controller.state, .thinking)
    }

    /// REQ-05
    func testEachUtteranceGetsItsOwnID() {
        say("first question")
        controller.replyFinished()
        say("second question")
        XCTAssertEqual(turns.map(\.text), ["first question", "second question"])
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    // MARK: 2, 5 — late results from a stopped pass

    /// REQ-02 REQ-05 REQ-14
    func testLateFinalFromAStoppedPassNeverSubmits() {
        pipeline.hear("tell me a joke")
        let stoppedPass = try! XCTUnwrap(pipeline.livePass)
        pipeline.endpoint()
        XCTAssertNil(pipeline.livePass, "submitting stops the pass")

        // Apple delivers the stopped pass's final ~1 s later.
        pipeline.speech.receiveRecognitionForTesting(pass: stoppedPass, text: "tell me a joke", isFinal: true)
        controller.replyFinished()
        pipeline.speech.receiveRecognitionForTesting(pass: stoppedPass, text: "tell me a joke", isFinal: true)
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["tell me a joke"])
    }

    /// The pre-#214 duplicate: the late final landed while audio (the cue)
    /// was playing and took the barge-in path, which submitted it again.
    /// REQ-02 REQ-05 REQ-14
    func testLateFinalWhileReplyPlaysIsNeitherATurnNorABargeIn() {
        pipeline.hear("tell me a joke")
        let stoppedPass = try! XCTUnwrap(pipeline.livePass)
        pipeline.endpoint()
        controller.replyStarted()
        pipeline.speech.receiveRecognitionForTesting(pass: stoppedPass, text: "tell me a joke", isFinal: true)
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(pipeline.events, [])
        XCTAssertEqual(turns.count, 1)
    }

    // MARK: 7 — turn-taking

    /// REQ-07
    func testNothingSubmitsWhileThinkingOrSpeaking() {
        say("first")
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(pipeline.speech.mode, .off)
        pipeline.hear("background chatter")
        pipeline.endpoint()

        controller.replyStarted()
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["first"])

        controller.replyFinished()
        XCTAssertEqual(controller.state, .listening, "listening resumes when playback finishes")
        XCTAssertEqual(pipeline.speech.mode, .listening)
        say("second")
        XCTAssertEqual(turns.map(\.text), ["first", "second"])
    }

    /// REQ-03 REQ-07
    func testTypedTurnAlsoStopsListeningUntilTheReplyFinishes() {
        controller.turnStarted()
        XCTAssertEqual(controller.state, .thinking)
        say("ignored")
        XCTAssertTrue(turns.isEmpty)
        controller.replyFinished()
        say("heard")
        XCTAssertEqual(turns.map(\.text), ["heard"])
    }

    // MARK: 8 — barge-in never submits

    /// REQ-08 REQ-14
    func testBargeInNeverSubmits() {
        turnWithPlayingReply()
        pipeline.hear("wait")
        pipeline.hear("wait a second", final: true)
        XCTAssertEqual(controller.state, .pausedAwaitingContinue)
        XCTAssertEqual(pipeline.events, ["pause"], "the rest of the reply is kept, not discarded")
        XCTAssertEqual(turns.count, 1, "barge-in submits nothing")
        XCTAssertEqual(pipeline.speech.mode, .listening)
    }

    /// REQ-08 (B1): the words that barged in are kept. The live pass keeps
    /// listening under a new utterance id; the debounce submits them.
    func testBargeInKeepsTheWordsAndTheDebounceSubmitsThem() {
        turnWithPlayingReply()
        let watchPass = pipeline.livePass
        let watchUtterance = pipeline.speech.utteranceIDForTesting
        pipeline.hear("wait actually")
        XCTAssertEqual(controller.state, .pausedAwaitingContinue)
        XCTAssertEqual(pipeline.livePass, watchPass, "the live pass keeps listening")
        XCTAssertNotEqual(pipeline.speech.utteranceIDForTesting, watchUtterance, "a new utterance id")
        pipeline.hear("wait actually what about tomorrow")
        XCTAssertEqual(turns.count, 1)
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["tell me a story", "wait actually what about tomorrow"])
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    /// REQ-08 (N7): one word over the reply is not a barge-in.
    func testOneWordDoesNotBargeIn() {
        turnWithPlayingReply()
        pipeline.hear("um")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(pipeline.events, [])
        pipeline.hear("um wait")
        XCTAssertEqual(controller.state, .pausedAwaitingContinue)
    }

    // MARK: 9 — the continue prompt

    /// REQ-09
    func testSpokenYesResumes() {
        turnWithPlayingReply()
        pipeline.hear("hold on")
        say("yes")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(pipeline.events, ["pause", "resume"])
        XCTAssertEqual(turns.count, 1, "yes is an answer, not a turn")
    }

    /// REQ-09
    func testSpokenNoEndsTheReply() {
        turnWithPlayingReply()
        pipeline.hear("hold on")
        say("no thanks")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(pipeline.events, ["pause", "discard"])
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(turns.count, 1)
    }

    /// REQ-09
    func testAnythingElseIsANewTurnAndDropsThePausedReply() {
        turnWithPlayingReply()
        pipeline.hear("hold on")
        say("what's the capital of France")
        XCTAssertEqual(pipeline.events, ["pause", "discard"])
        XCTAssertEqual(turns.map(\.text), ["tell me a story", "what's the capital of France"])
        XCTAssertEqual(controller.state, .thinking)
    }

    /// REQ-09
    func testTappedAnswersGoThroughTheSameResolution() {
        turnWithPlayingReply()
        pipeline.hear("hold on")
        controller.answerContinue(true)
        XCTAssertEqual(controller.state, .speaking)
        pipeline.hear("hold on again")
        controller.answerContinue(false)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(pipeline.events, ["pause", "resume", "pause", "discard"])
        XCTAssertEqual(turns.count, 1)
    }

    /// REQ-09
    func testYesWithNothingLeftToPlayReturnsToListening() {
        turnWithPlayingReply()
        pipeline.hear("hold on")
        pipeline.replyAudioLeft = false
        say("yes")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(turns.count, 1)
    }

    // MARK: 10 — echo by playback state, never transcript matching

    /// REQ-10
    func testWithoutEchoCancellationTheMicIsOffDuringPlayback() {
        pipeline.bargeInAvailable = false
        turnWithPlayingReply()
        XCTAssertEqual(pipeline.speech.mode, .off)
        pipeline.hear("our own reply leaking back")
        pipeline.endpoint()
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(turns.count, 1)
    }

    /// REQ-10 REQ-15
    func testWordsThatMatchTheReplyStillCount() {
        // No transcript matching: the user repeating the reply is a real turn.
        say("tell me a story")
        controller.replyFinished()
        say("tell me a story")
        XCTAssertEqual(turns.count, 2)
    }

    /// REQ-10
    func testMicGateFollowsPlaybackState() {
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .off, replyPlaying: false, echoCancelled: true, roomTailQuiet: true))
        XCTAssertTrue(VoiceListenGate.feedsRecognizer(mode: .listening, replyPlaying: false, echoCancelled: false, roomTailQuiet: true))
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .listening, replyPlaying: false, echoCancelled: true, roomTailQuiet: false))
        XCTAssertTrue(VoiceListenGate.feedsRecognizer(mode: .watchingForBargeIn, replyPlaying: true, echoCancelled: true, roomTailQuiet: false))
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .watchingForBargeIn, replyPlaying: true, echoCancelled: false, roomTailQuiet: true))
    }

    // MARK: 11 — Stop and Back

    /// REQ-11
    func testStopIsInstantIdempotentAndNoLateCallbackActs() async {
        pipeline.hear("half a sent")
        let pass = try! XCTUnwrap(pipeline.livePass)
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        pipeline.speech.receiveRecognitionForTesting(pass: pass, text: "half a sentence", isFinal: true)
        pipeline.endpoint()
        await controller.waitUntilSettled()
        pipeline.speech.receiveRecognitionForTesting(pass: pass, text: "half a sentence", isFinal: true)
        pipeline.endpoint()
        XCTAssertTrue(turns.isEmpty)
        XCTAssertEqual(pipeline.speech.mode, .off)
    }

    /// REQ-11
    func testBackDuringAReplyIsInstantAndNoLateCallbackActs() async {
        turnWithPlayingReply()
        pipeline.hear("wai")
        controller.leave()
        XCTAssertEqual(controller.state, .idle)
        controller.leave()
        controller.replyFinished()
        controller.replyStarted()
        pipeline.endpoint()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(turns.count, 1)
    }

    // MARK: 12 — recovery

    /// REQ-12
    func testRouteChangeStartsAFreshPassAndNeitherLosesNorReplaysTheTurn() {
        pipeline.hear("what's the weather")
        let oldPass = try! XCTUnwrap(pipeline.livePass)
        let oldUtterance = pipeline.speech.utteranceIDForTesting
        pipeline.speech.restartRecognizerForTesting() // route change / interruption
        XCTAssertNotEqual(pipeline.livePass, oldPass)
        XCTAssertNotEqual(pipeline.speech.utteranceIDForTesting, oldUtterance)

        pipeline.speech.receiveRecognitionForTesting(pass: oldPass, text: "what's the weather", isFinal: true)
        pipeline.hear("in Paris")
        pipeline.endpoint()
        pipeline.speech.receiveRecognitionForTesting(pass: oldPass, text: "what's the weather", isFinal: true)
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["what's the weather in Paris"])
    }

    /// REQ-12
    func testRecognizerErrorStartsAFreshPass() {
        pipeline.hear("hello")
        let oldPass = try! XCTUnwrap(pipeline.livePass)
        pipeline.speech.failRecognitionForTesting(pass: oldPass)
        XCTAssertNotNil(pipeline.livePass)
        XCTAssertNotEqual(pipeline.livePass, oldPass)
        pipeline.endpoint()
        XCTAssertEqual(turns.map(\.text), ["hello"])
    }

    /// REQ-05 REQ-12
    func testRecoveryAfterTheTurnWasSubmittedReplaysNothing() {
        say("what's the weather")
        pipeline.speech.restartRecognizerForTesting()
        XCTAssertNil(pipeline.livePass, "no pass while thinking")
        controller.replyFinished()
        pipeline.endpoint()
        XCTAssertEqual(turns.count, 1)
    }
}

/// Requirement 14: two quick spoken turns produce exactly one reply. The
/// real controller and recognizer owner feed the real submit point.
@MainActor
final class VoiceTwoQuickTurnsTests: XCTestCase {
    /// REQ-06 REQ-14
    func testTwoQuickSpokenTurnsProduceExactlyOneReply() async {
        let pipeline = RecognizerBackedPipeline()
        let controller = VoiceSessionController(backend: pipeline)
        controller.onFailure = { _, _ in }
        let submitter = ChatTurnSubmitter(runs: BackgroundRunCenter())
        var userMessages: [String] = []
        var replies: [String] = []
        let (gate, open) = AsyncStream<Void>.makeStream()
        controller.onTurn = { utterance in
            return submitter.submit(
                chatID: "chat", text: utterance.text, utteranceID: utterance.id, execution: .cloud,
                record: { userMessages.append(utterance.text) }
            ) { _ in
                for await _ in gate { break }
                try Task.checkCancellation()
                replies.append(utterance.text)
            }
        }
        controller.start()
        await controller.waitUntilSettled()

        // Turn 1, plus the stopped pass's late final (the pre-#214 duplicate).
        pipeline.hear("tell me a story")
        let firstPass = pipeline.livePass!
        pipeline.endpoint()
        pipeline.speech.receiveRecognitionForTesting(pass: firstPass, text: "tell me a story", isFinal: true)
        pipeline.endpoint()

        // Turn 2 right away: speech over the starting reply, then a new question.
        controller.replyStarted()
        pipeline.hear("actually")
        pipeline.hear("what's the weather")
        pipeline.endpoint()

        open.yield()
        open.yield()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(userMessages, ["tell me a story", "what's the weather"])
        XCTAssertEqual(replies, ["what's the weather"], "the second turn cancelled the first reply")
        controller.stop()
        await controller.waitUntilSettled()
    }
}

/// REQ-15: the listening cue is not reply playback.
@MainActor
final class VoiceListeningCuePlaybackTests: XCTestCase {
    /// REQ-15
    func testCueDoesNotGateTheMicAsPlayback() async throws {
        let fake = BlockingFakeAudioGraph()
        fake.startDelay = 0
        fake.holdsCompletions = true
        let engine = VoiceDuplexEngine(graph: fake)
        try await engine.prepareAsync(enableAEC: false)
        engine.scheduleCue(pcmData: try XCTUnwrap(VoiceListeningCue.tonePCM()), sampleRate: VoiceListeningCue.sampleRate)
        await engine.waitUntilGraphIdle()
        XCTAssertTrue(fake.calls.contains("schedule"), "\(fake.calls)")
        XCTAssertFalse(engine.isPlayingBack)
        XCTAssertFalse(engine.hasPendingPlayback)
        XCTAssertTrue(engine.micAcceptsSpeech)
    }
}

/// Text-only callers (was N6) re-arm listening after each utterance, so
/// voice hears every command, not only the first.
@MainActor
final class RelistenTests: XCTestCase {
    /// REQ-02, REQ-05: each command arrives once, each on a fresh pass.
    func testREQ05_TextOnlyCallerHearsEveryCommand() async throws {
        let speech = SystemSpeechInputService(hardwareFreeForTesting: true)
        var heard: [String] = []
        try await speech.beginContinuousListening(relistenAfterEachUtterance: true) { heard.append($0) }
        var passes: Set<Int> = []
        for command in ["open the file", "go to line ten", "save it"] {
            let pass = try XCTUnwrap(speech.livePassIDForTesting, "listening before \(command)")
            passes.insert(pass)
            speech.receiveRecognitionForTesting(pass: pass, text: command, isFinal: false)
            speech.endpointForTesting()
        }
        XCTAssertEqual(heard, ["open the file", "go to line ten", "save it"])
        XCTAssertEqual(passes.count, 3, "a new pass per command")
        XCTAssertEqual(speech.mode, .listening)
        speech.endContinuousListening()
        XCTAssertEqual(speech.mode, .off)
    }

    /// Without re-arming the mic goes quiet after the first command (the old bug).
    func testWithoutRelistenTheMicStopsAfterOneUtterance() async throws {
        let speech = SystemSpeechInputService(hardwareFreeForTesting: true)
        try await speech.beginContinuousListening { _ in }
        let pass = try XCTUnwrap(speech.livePassIDForTesting)
        speech.receiveRecognitionForTesting(pass: pass, text: "open the file", isFinal: false)
        speech.endpointForTesting()
        XCTAssertEqual(speech.mode, .off)
        speech.endContinuousListening()
    }
}
