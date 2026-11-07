// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AVFoundation
import XCTest
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// REQ-15: the app never hears or transcribes its own reply and never
/// barges in on it. The harness feeds the reply's own audio back into the
/// mic path; the engine tests check the runtime echo check in the engine
/// owner. Real acoustic cancellation is a manual device check (see the doc).
@MainActor
final class VoiceEchoRequirementTests: XCTestCase {
    private var h: VoiceHarness!
    private let reply = "once upon a time there was a dragon"

    override func setUp() async throws {
        h = VoiceHarness()
        await h.start()
    }

    override func tearDown() async throws {
        await h.stop()
        h = nil
    }

    /// Our reply, buffer by buffer, back into the mic for the whole reply,
    /// the end of the run, the drain and the room tail.
    private func feedReplyIntoMic() {
        var words: [String] = []
        for word in reply.split(separator: " ") {
            words.append(String(word))
            h.micBuffer(.reply, words: words.joined(separator: " "))
            h.clock.advance(0.2)
        }
    }

    private func assertNothingHeard(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.offered.map(\.text), ["tell me a story"], "no utterance", file: file, line: line)
        XCTAssertEqual(h.turns.count, 1, "no submit", file: file, line: line)
        XCTAssertFalse(h.playback.events.contains("pause"), "no barge-in", file: file, line: line)
    }

    private func runReplyWithEcho() async {
        h.say("tell me a story")
        feedReplyIntoMic()                 // thinking: mic off
        h.replyStartsPlaying()
        feedReplyIntoMic()                 // speaking
        h.replyRunEnds()                   // run ends, audio still playing
        await h.settle()
        feedReplyIntoMic()
        h.playback.drain()
        await h.settle()
        h.micBuffer(.reply, words: "dragon") // the room tail
        h.silence(3)
    }

    /// REQ-15: speaker with verified echo cancellation.
    func testREQ15_OwnReplyIsNeverHeardOnSpeakerWithAEC() async {
        await runReplyWithEcho()
        assertNothingHeard()
        XCTAssertEqual(h.controller.state, .listening)
    }

    /// REQ-15: headphones.
    func testREQ15_OwnReplyIsNeverHeardOnHeadphones() async {
        h.route = .headphones
        await runReplyWithEcho()
        assertNothingHeard()
    }

    /// REQ-15: Bluetooth HFP has no AEC: the mic is closed during playback.
    func testREQ15_OwnReplyIsNeverHeardOnHFP() async {
        h.route = .bluetoothHFP
        await runReplyWithEcho()
        assertNothingHeard()
    }

    /// REQ-15: the engine's echo check failed: the mic is closed during
    /// playback on every route, so the reply can't reach the recognizer.
    func testREQ15_FailedEchoCheckClosesTheMicDuringPlayback() async {
        h.route = .speakerAECCheckFailed
        h.say("tell me a story")
        h.replyStartsPlaying()
        XCTAssertEqual(h.speech.mode, .off)
        XCTAssertFalse(h.micBuffer(.reply, words: "once upon a time"))
        XCTAssertFalse(h.micBuffer(.user, words: "stop that"), "the user taps to interrupt")
        assertNothingHeard()
    }

    /// REQ-15: the build-38 echo. Reply audio still playing after listening
    /// resumed is never fed to the recognizer while listening for a turn.
    func testREQ15_LateReplyAudioWhileListeningIsNotHeard() {
        h.say("tell me a story")
        h.replyRunEnds()                   // run ended before any audio
        XCTAssertEqual(h.controller.state, .listening)
        h.playback.startReply()            // the reply's audio arrives late
        XCTAssertFalse(h.micBuffer(.reply, words: "once upon a time"))
        h.route = .bluetoothHFP
        XCTAssertFalse(h.micBuffer(.reply, words: "once upon a time"))
        h.silence(3)
        assertNothingHeard()
    }

    /// REQ-15: no transcript text matching. The gate decides from playback
    /// and route state only.
    func testREQ15_GateUsesPlaybackStateOnly() {
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .listening, replyPlaying: true, echoCancelled: true, roomTailQuiet: true))
        XCTAssertTrue(VoiceListenGate.feedsRecognizer(mode: .watchingForBargeIn, replyPlaying: true, echoCancelled: true, roomTailQuiet: false))
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .watchingForBargeIn, replyPlaying: true, echoCancelled: false, roomTailQuiet: true))
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(mode: .listening, replyPlaying: false, echoCancelled: true, roomTailQuiet: false))
    }

    /// REQ-15: a streamed reply is finished only when the audio for its last
    /// text has arrived and gone quiet, not when nothing happens to be queued.
    func testREQ15_TTSFinishWaitsForAudioStillOnTheWire() {
        let sent: TimeInterval = 100
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: sent + 0.1, lastTextSentAt: sent, lastAudioAt: nil, playbackPending: false))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: sent + 1, lastTextSentAt: sent, lastAudioAt: sent + 0.5, playbackPending: false))
        XCTAssertFalse(VoiceTTSDrainPolicy.isDrained(now: sent + 5, lastTextSentAt: sent, lastAudioAt: sent + 0.5, playbackPending: true))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: sent + 1.4, lastTextSentAt: sent, lastAudioAt: sent + 0.5, playbackPending: false))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: sent + VoiceTTSDrainPolicy.firstAudioTimeout, lastTextSentAt: sent, lastAudioAt: nil, playbackPending: false))
        XCTAssertTrue(VoiceTTSDrainPolicy.isDrained(now: 0, lastTextSentAt: nil, lastAudioAt: nil, playbackPending: false))
    }
}

/// REQ-15: the runtime echo check in the engine owner, over a fake graph
/// with a fake route and session mode.
@MainActor
final class VoiceEngineEchoCheckTests: XCTestCase {
    private var fake: BlockingFakeAudioGraph!
    private var engine: VoiceDuplexEngine!
    private var log: VoiceLogCapture!

    override func setUp() async throws {
        VoiceRouteMonitor.routeOverrideForTesting = .speaker
        VoiceAudioSession.voiceChatOverrideForTesting = true
        fake = BlockingFakeAudioGraph()
        fake.startDelay = 0
        engine = VoiceDuplexEngine(graph: fake)
        log = VoiceLogCapture()
    }

    override func tearDown() async throws {
        log.stop()
        VoiceRouteMonitor.routeOverrideForTesting = nil
        VoiceAudioSession.voiceChatOverrideForTesting = nil
    }

    /// REQ-15: at session start voice processing is on for the input node the
    /// recognizer taps, the player is on the same engine, the mode is voiceChat.
    func testREQ15_SessionStartVerifiesVoiceProcessingPlayerAndMode() async throws {
        try await engine.prepareAsync(enableAEC: true)
        XCTAssertTrue(fake.isVoiceProcessingEnabled)
        XCTAssertTrue(engine.isTapInstalledForTesting)
        let check = try XCTUnwrap(engine.lastEchoCheck)
        XCTAssertTrue(check.passes, check.detail)
        XCTAssertTrue(check.playerOnSameEngine)
        XCTAssertTrue(check.sessionIsVoiceChat)
        XCTAssertFalse(engine.echoCheckFailed)
        XCTAssertEqual(log.lines("voice.aec.ok").count, 1)
        XCTAssertTrue(log.lines("voice.aec.disabled").isEmpty)
    }

    /// REQ-15: a live graph that skips its rebuild at session start is still checked.
    func testREQ15_CheckRunsWhenSessionStartSkipsTheRebuild() async throws {
        try await engine.prepareAsync(enableAEC: true)
        try await engine.prepareAsync(enableAEC: true)
        XCTAssertEqual(log.lines("voice.aec.ok").count, 2)
    }

    /// REQ-15: a route change that skips the rebuild still re-runs the echo
    /// check, and voice processing that the change turned off is re-enabled.
    func testREQ15_RouteChangeThatSkipsTheRebuildIsChecked() async throws {
        try await engine.prepareAsync(enableAEC: true)
        try fake.setVoiceProcessing(false)
        engine.handleExternalGraphChange(event: .routeChanged)
        await engine.waitUntilGraphIdle()
        XCTAssertEqual(log.lines("voice.aec.check.failed").count, 1)
        XCTAssertEqual(log.lines("voice.aec.reenabled").count, 1)
        XCTAssertTrue(fake.isVoiceProcessingEnabled)
        XCTAssertFalse(engine.echoCheckFailed)
    }

    /// REQ-08 (re-review blocker): pausing for a barge-in on an echo-cancelled
    /// route doesn't start the 0.6 s tail guard; the user's next words are heard.
    func testREQ08_BargeInPauseDoesNotStartTheTailGuard() async throws {
        try await engine.prepareAsync(enableAEC: true)
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000)
        XCTAssertTrue(engine.isPlayingBack)
        engine.pausePlayback()
        XCTAssertTrue(engine.micAcceptsSpeech, "right after the pause")
    }

    /// REQ-10: without echo cancellation a paused reply's room tail is still guarded.
    func testREQ10_PauseWithoutEchoCancellationGuardsTheTail() async throws {
        VoiceRouteMonitor.routeOverrideForTesting = .bluetoothHFP
        try await engine.prepareAsync(enableAEC: true)
        engine.schedule(pcmData: Data(count: 48_000), sampleRate: 24_000)
        engine.pausePlayback()
        XCTAssertFalse(engine.micAcceptsSpeech)
    }

    /// REQ-15: a rebuild that turns voice processing off is caught and
    /// voice processing is re-enabled once.
    func testREQ15_RebuildThatDropsVoiceProcessingIsReEnabled() async throws {
        try await engine.prepareAsync(enableAEC: true)
        fake.dropsVoiceProcessingOnStart = 1
        fake.sampleRate = 16_000 // a real route change: the graph rebuilds
        engine.handleExternalGraphChange(event: .routeChanged)
        await engine.waitUntilGraphIdle()
        XCTAssertEqual(log.lines("voice.aec.check.failed").count, 1)
        XCTAssertEqual(log.lines("voice.aec.reenabled").count, 1)
        XCTAssertTrue(fake.isVoiceProcessingEnabled, "re-enabled")
        XCTAssertEqual(fake.voiceProcessingWrites.last, true)
        XCTAssertFalse(engine.echoCheckFailed)
        XCTAssertTrue(engine.lastEchoCheck?.passes == true)
        XCTAssertTrue(engine.isRunningForTesting, "the engine runs again after the repair")
    }

    /// REQ-15: still off after the retry: `voice.aec.disabled` is logged and
    /// the mic stays closed during playback.
    func testREQ15_VoiceProcessingThatStaysOffClosesTheMicDuringPlayback() async throws {
        fake.refusesVoiceProcessing = true
        fake.holdsCompletions = true
        try await engine.prepareAsync(enableAEC: true)
        let disabled = log.lines("voice.aec.disabled")
        XCTAssertEqual(disabled.count, 1)
        XCTAssertTrue(disabled[0].contains("voiceProcessing=off"), disabled[0])
        XCTAssertTrue(engine.echoCheckFailed)
        engine.schedule(pcmData: Data(count: 4_800), sampleRate: 24_000)
        XCTAssertTrue(engine.isPlayingBack)
        XCTAssertFalse(engine.micAcceptsSpeech, "the mic is closed while our reply plays")
        XCTAssertFalse(VoiceListenGate.feedsRecognizer(
            mode: .watchingForBargeIn, replyPlaying: engine.isPlayingBack,
            echoCancelled: !engine.echoCheckFailed && engine.lastEchoCheck?.echoCancelled == true,
            roomTailQuiet: engine.micAcceptsSpeech
        ))
    }

    /// REQ-15: a session not in voiceChat mode fails the check.
    func testREQ15_SessionNotInVoiceChatFailsTheCheck() async throws {
        VoiceAudioSession.voiceChatOverrideForTesting = false
        try await engine.prepareAsync(enableAEC: true)
        XCTAssertTrue(log.lines("voice.aec.disabled").first?.contains("mode!=voiceChat") == true)
        XCTAssertTrue(engine.echoCheckFailed)
    }

    /// REQ-15: a player that isn't attached to the engine the recognizer taps
    /// fails the check (its audio would never be cancelled).
    func testREQ15_PlayerOnAnotherEngineFailsTheCheck() async throws {
        fake.playerAttachedToEngine = false
        try await engine.prepareAsync(enableAEC: true)
        XCTAssertTrue(fake.calls.contains("reconnect"), "tried to reattach once")
        XCTAssertTrue(log.lines("voice.aec.disabled").first?.contains("player=detached") == true)
        XCTAssertTrue(engine.echoCheckFailed)
    }

    /// REQ-15: HFP can't run Apple's voice processing; the check doesn't
    /// demand it there (the mic is closed during playback instead).
    func testREQ15_HFPDoesNotRequireVoiceProcessing() {
        let check = VoiceEchoCheck(voiceProcessingExpected: false, voiceProcessingOn: false, playerOnSameEngine: true, sessionIsVoiceChat: true)
        XCTAssertTrue(check.passes)
        XCTAssertFalse(check.echoCancelled, "no speech during playback on HFP")
        XCTAssertFalse(VoiceEchoPolicy.allowsSpeechBargeIn(route: .bluetoothHFP, acousticEchoCancellationAvailable: true))
    }

    /// REQ-15: reply audio and the cue are scheduled on that same graph.
    func testREQ15_ReplyAndCuePlayThroughTheVoiceProcessedEngine() async throws {
        try await engine.prepareAsync(enableAEC: true)
        fake.resetCalls()
        engine.schedule(pcmData: Data(count: 4_800), sampleRate: 24_000)
        engine.scheduleCue(pcmData: try XCTUnwrap(VoiceListeningCue.tonePCM()), sampleRate: VoiceListeningCue.sampleRate)
        await engine.waitUntilGraphIdle()
        XCTAssertEqual(fake.calls.filter { $0 == "schedule" }.count, 2, "\(fake.calls)")
        XCTAssertTrue(fake.isVoiceProcessingEnabled)
    }

    #if os(iOS)
    /// REQ-15: the spoken-conversation session is playAndRecord in voiceChat mode.
    func testREQ15_SessionIsPlayAndRecordVoiceChat() {
        XCTAssertEqual(VoiceAudioSession.spokenConversationCategory, .playAndRecord)
        XCTAssertEqual(VoiceAudioSession.spokenConversationMode, .voiceChat)
    }
    #endif
}

/// Source guards for REQ-01 and REQ-15 (they read the repo; skipped where
/// the test bundle runs without the sources).
final class VoiceSourceGuardTests: XCTestCase {
    private func voiceSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("AIConnectVoice/Sources/AIConnectVoice/Voice")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("repository sources not available at \(dir.path)")
        }
        return try names.filter { $0.hasSuffix(".swift") }.map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// REQ-01: Apple Speech is the only speech-to-text path; no server STT.
    func testREQ01_NoServerSpeechToText() throws {
        for (name, text) in try voiceSources() {
            XCTAssertFalse(text.contains("/v1/speech-to-text"), name)
            XCTAssertFalse(text.contains("func transcribe"), name)
            if name != "SpeechInputService.swift" {
                XCTAssertFalse(text.contains("SFSpeechRecognizer("), "\(name): only the one owner creates a recognizer")
            }
        }
    }

    /// REQ-15: one engine. No second AVAudioEngine; AVAudioPlayer and direct
    /// AVSpeechSynthesizer playback only in the Settings voice preview (and
    /// the cue's player when voice control is off).
    func testREQ15_NoSecondEngineOrPlayerInTheVoicePath() throws {
        for (name, text) in try voiceSources() {
            if name != "VoiceDuplexEngine.swift" {
                XCTAssertFalse(text.contains("AVAudioEngine()"), name)
            }
            if !["VoicePreviewService.swift", "VoiceListeningCue.swift"].contains(name) {
                XCTAssertFalse(text.contains("AVAudioPlayer("), name)
            }
            if name != "VoicePreviewService.swift" {
                XCTAssertFalse(text.contains("synthesizer.speak("), "\(name): system TTS must be written into the engine")
            }
        }
    }
}

/// REQ-15 UX: when barge-in is off the voice-mode line names the route.
@MainActor
final class VoiceInterruptHintTests: XCTestCase {
    override func tearDown() async throws {
        VoiceRouteMonitor.routeOverrideForTesting = nil
    }

    /// REQ-15, REQ-10: no AEC or a failed echo check turns barge-in off and
    /// shows a route-specific line; with barge-in on there is no line.
    func testREQ15_InterruptOffLineFitsTheRoute() {
        XCTAssertEqual(VoiceInterruptHintPolicy.text(route: .speaker, speechBargeInEnabled: false),
                       "Interrupting is off on the speaker. Use headphones to interrupt.")
        XCTAssertEqual(VoiceInterruptHintPolicy.text(route: .bluetoothHFP, speechBargeInEnabled: false),
                       "Interrupting is off on this headset. Tap to interrupt.")
        XCTAssertNotNil(VoiceInterruptHintPolicy.text(route: .headphones, speechBargeInEnabled: false))
        XCTAssertNil(VoiceInterruptHintPolicy.text(route: .speaker, speechBargeInEnabled: true))
    }

    /// REQ-15: on HFP the live route monitor turns barge-in off and shows the headset line.
    func testREQ15_HFPRouteShowsTheHeadsetLine() {
        VoiceRouteMonitor.routeOverrideForTesting = .bluetoothHFP
        XCTAssertFalse(VoiceRouteMonitor.speechBargeInEnabled)
        XCTAssertEqual(VoiceRouteMonitor.interruptHint, VoiceInterruptHintPolicy.headset)
    }

    /// REQ-15: a failed echo check on the speaker turns barge-in off: the
    /// session closes the mic during playback and shows the speaker line.
    func testREQ15_FailedEchoCheckTurnsBargeInOffAndShowsTheLine() async {
        let h = VoiceHarness()
        h.route = .speakerAECCheckFailed
        await h.start()
        h.say("tell me a story")
        h.replyStartsPlaying()
        XCTAssertEqual(h.speech.mode, .off, "mic closed during playback")
        XCTAssertEqual(VoiceInterruptHintPolicy.text(route: h.route.kind, speechBargeInEnabled: h.speechBargeInAvailable),
                       VoiceInterruptHintPolicy.speaker)
        await h.stop()
    }
}
