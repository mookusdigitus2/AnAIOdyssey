// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AVFoundation
import XCTest
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

// Reusable harness for AnAIOdyssey/docs/VOICE_MODE_REQUIREMENTS.md. Real code
// under test: SystemSpeechInputService (the one recognizer owner, minus the
// microphone and Apple's recognizer), VoiceSessionController and
// ChatTurnSubmitter. Faked: the recognizer's callbacks, reply playback, the
// clock, and the route / echo-cancellation state.

/// Fake clock for the 1.5 s debounce and the recovery backoff.
final class FakeVoiceClock: VoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Fake route and echo-cancellation state.
struct FakeAudioRoute {
    var kind: VoiceOutputRouteKind = .speaker
    /// Voice processing running and verified by the engine's echo check.
    var echoCancellationVerified = true

    var echoCancelled: Bool {
        echoCancellationVerified && VoiceEchoPolicy.allowsSpeechBargeIn(
            route: kind, acousticEchoCancellationAvailable: echoCancellationVerified
        )
    }

    static let speakerWithAEC = FakeAudioRoute()
    static let headphones = FakeAudioRoute(kind: .headphones)
    static let bluetoothHFP = FakeAudioRoute(kind: .bluetoothHFP, echoCancellationVerified: false)
    static let speakerAECCheckFailed = FakeAudioRoute(kind: .speaker, echoCancellationVerified: false)
}

/// Fake reply playback: queued, playing, paused, drained.
@MainActor
final class FakePlaybackEngine {
    private(set) var queued = false
    private(set) var paused = false
    private(set) var events: [String] = []
    private var endedAt: TimeInterval?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let clock: FakeVoiceClock

    init(clock: FakeVoiceClock) { self.clock = clock }

    var isPlaying: Bool { queued && !paused }
    /// The 0.6 s room tail after playback ends.
    var roomTailQuiet: Bool {
        guard let endedAt else { return true }
        return clock.now - endedAt >= VoiceMicGate.tailGuardSeconds
    }

    func startReply() { queued = true; paused = false; events.append("play") }
    /// Like `VoiceDuplexEngine.pausePlayback`: the pause starts the room-tail
    /// guard only where nothing cancels the echo.
    func pause(echoCancelled: Bool) {
        if queued, !paused, VoiceMicGate.pauseStartsTailGuard(echoCancelled: echoCancelled) { endedAt = clock.now }
        paused = true
        events.append("pause")
    }
    func resume() { paused = false; events.append("resume") }
    func discard() { events.append("discard"); end() }
    func stop() { end() }
    /// The last buffer played out.
    func drain() { events.append("drained"); end() }

    func waitUntilDrained() async {
        guard queued else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func end() {
        if queued { endedAt = clock.now }
        queued = false
        paused = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// The whole voice loop on fakes. It is the controller's pipeline backend;
/// turns go through the real `ChatTurnSubmitter`.
@MainActor
final class VoiceHarness: VoicePipelineBackend {
    let clock = FakeVoiceClock()
    let playback: FakePlaybackEngine
    var route = FakeAudioRoute.speakerWithAEC
    let speech: SystemSpeechInputService
    private(set) var controller: VoiceSessionController!
    let submitter = ChatTurnSubmitter(runs: BackgroundRunCenter())
    /// User turns the submit point accepted.
    private(set) var turns: [VoiceUtterance] = []
    /// Utterances that reached the controller's `onTurn` (accepted or not).
    private(set) var offered: [VoiceUtterance] = []
    private(set) var failures: [String] = []
    private(set) var discarded = 0
    /// False: the submit point refuses every turn.
    var submitAccepts = true

    init() {
        playback = FakePlaybackEngine(clock: clock)
        speech = SystemSpeechInputService(hardwareFreeForTesting: true, clock: clock)
        speech.micConditionsForTesting = { [unowned self] in
            VoiceMicConditions(
                replyPlaying: playback.isPlaying,
                echoCancelled: route.echoCancelled,
                roomTailQuiet: playback.roomTailQuiet
            )
        }
        controller = VoiceSessionController(backend: self)
        controller.onFailure = { [unowned self] message, _ in failures.append(message) }
        controller.onReplyDiscarded = { [unowned self] in discarded += 1 }
        controller.onTurn = { [unowned self] utterance in
            offered.append(utterance)
            guard submitAccepts else { return false }
            return submitter.submit(
                chatID: "chat", text: utterance.text, utteranceID: utterance.id, execution: .cloud,
                record: { self.turns.append(utterance) }
            ) { _ in }
        }
    }

    func start() async {
        controller.start()
        await controller.waitUntilSettled()
    }

    func stop() async {
        controller.stop()
        await controller.waitUntilSettled()
    }

    // MARK: VoicePipelineBackend

    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        try await speech.beginContinuousListening(onEvent: onEvent)
    }
    func setListenMode(_ mode: VoiceListenMode) { speech.setMode(mode) }
    func silenceImmediately() { speech.setMode(.off); playback.stop() }
    func teardownPipeline() async { speech.endContinuousListening() }
    var micLevel: Double { 0 }
    var hasLiveAudio: Bool { false }
    var speechBargeInAvailable: Bool { route.echoCancelled }
    func pauseReplyPlayback() { playback.pause(echoCancelled: route.echoCancelled) }
    func resumeReplyPlayback() { playback.resume() }
    func discardReplyPlayback() { playback.discard() }
    var hasReplyAudioLeft: Bool { playback.queued }
    var isReplyAudioPlaying: Bool { playback.isPlaying }
    func waitUntilReplyDrained() async { await playback.waitUntilDrained() }
    var recognizerIDs: String { speech.currentIDs }

    // MARK: Fake recognizer

    var livePass: Int? { speech.livePassIDForTesting }
    var utteranceID: Int { speech.utteranceIDForTesting }

    /// A partial result on the live pass (cumulative text, like Apple's).
    func partial(_ text: String) {
        guard let pass = livePass else { return }
        speech.receiveRecognitionForTesting(pass: pass, text: text, isFinal: false)
    }

    /// A final result on the live pass (Apple ending the pass itself).
    func final(_ text: String) {
        guard let pass = livePass else { return }
        speech.receiveRecognitionForTesting(pass: pass, text: text, isFinal: true)
    }

    /// A late or stale result from a pass that is no longer live.
    func late(pass: Int, _ text: String, final: Bool = true) {
        speech.receiveRecognitionForTesting(pass: pass, text: text, isFinal: final)
    }

    /// The recognizer failing the live pass.
    func fail() {
        guard let pass = livePass else { return }
        speech.failRecognitionForTesting(pass: pass)
    }

    /// Time passing with no new words and no voice, ticked like the 100 ms monitor.
    func silence(_ seconds: TimeInterval = 1.5) {
        var left = seconds
        while left > 0.0001 {
            let step = min(0.1, left)
            clock.advance(step)
            speech.tickForTesting()
            left -= step
        }
    }

    /// The user saying something, then the 1.5 s pause that ends it.
    func say(_ text: String) {
        partial(text)
        silence()
    }

    // MARK: Reply lifecycle, as ChatsView drives it

    /// First reply audio is playing.
    func replyStartsPlaying() {
        playback.startReply()
        controller.replyStarted()
    }

    /// The reply's run ended. Audio may still be playing.
    func replyRunEnds() { controller.replyFinished() }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: Mic path

    enum MicSource { case user, reply }

    /// One loud mic buffer. Returns whether the gate fed it to the
    /// recognizer. When it is fed, the fake recognizer hears `words`: the
    /// user always; our own reply only where nothing cancels it. (Real
    /// acoustic cancellation is a manual device check.)
    @discardableResult
    func micBuffer(_ source: MicSource, words: String) -> Bool {
        let fed = speech.feedMicForTesting(loud: true)
        guard fed else { return false }
        if source == .reply, route.echoCancelled { return true }
        partial(words)
        return true
    }
}

/// Captures VoiceAudioDebugStore lines while a test runs.
final class VoiceLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [(String, String)] = []

    init() {
        VoiceAudioDebugStore.observerForTesting = { [weak self] event, detail in
            guard let self else { return }
            self.lock.withLock { self.captured.append((event, detail)) }
        }
    }

    func stop() { VoiceAudioDebugStore.observerForTesting = nil }

    func lines(_ event: String) -> [String] {
        lock.withLock { captured.filter { $0.0 == event }.map(\.1) }
    }

    var events: [String] { lock.withLock { captured.map(\.0) } }
}
