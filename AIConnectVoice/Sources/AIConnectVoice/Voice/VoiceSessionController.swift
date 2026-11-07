// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation
import AIModelOptions

/// What the voice UI shows. There is deliberately no "stopping" state: Stop
/// flips straight to `.idle` and cleanup finishes in the background.
public enum VoiceSessionState: Equatable, Sendable {
    case idle
    case starting
    case listening
    /// A turn was submitted; its reply is generating. The mic is off.
    case thinking
    case speaking
    /// Speech barged in on a reply: playback is paused (audio keeps
    /// buffering), "Would you like me to continue?" is on screen, and the
    /// mic listens for the answer.
    case pausedAwaitingContinue
    case error(String)

    /// Any state but idle and error: the mic button reads "Exit voice control".
    public var isActive: Bool {
        switch self {
        case .starting, .listening, .thinking, .speaking, .pausedAwaitingContinue: return true
        case .idle, .error: return false
        }
    }
}

/// The audio pipeline behind a voice session. The controller is its only
/// caller, and it never runs two of the heavy operations at once.
@MainActor
public protocol VoicePipelineBackend: AnyObject {
    /// Heavy start: session activation, engine graph, mic tap, recognizer.
    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws
    /// What the recognizer listens for now.
    func setListenMode(_ mode: VoiceListenMode)
    /// Cheap and synchronous: stop playback and ignore mic buffers right now.
    /// Must not call `engine.stop()` or `setActive(false)`.
    func silenceImmediately()
    /// Heavy teardown, off the main thread: engine stop, tap removal, then
    /// session deactivation last. Called at most once per session.
    func teardownPipeline() async
    /// Latest mic RMS for the listening level ring.
    var micLevel: Double { get }
    /// True while something (engine, session, TTS) still holds audio.
    var hasLiveAudio: Bool { get }
    /// Echo cancellation or headphones keep the reply out of the mic, so
    /// speech can barge in. False on HFP: the user taps to interrupt.
    var speechBargeInAvailable: Bool { get }
    /// Barge-in: pause reply playback now; keep buffering incoming audio.
    func pauseReplyPlayback()
    /// Yes: resume from the pause point, buffered audio included.
    func resumeReplyPlayback()
    /// No, or a new turn: drop the paused reply's remaining audio.
    func discardReplyPlayback()
    /// True while reply audio is still queued or playing (paused counts).
    var hasReplyAudioLeft: Bool { get }
    /// True while reply audio is audibly playing (not paused).
    var isReplyAudioPlaying: Bool { get }
    /// Returns once queued reply audio has played out (or was dropped).
    func waitUntilReplyDrained() async
    /// The recognizer's "utt=<id> pass=<id>" for logs (req. 13).
    var recognizerIDs: String { get }
}

public extension VoicePipelineBackend {
    func setListenMode(_ mode: VoiceListenMode) {}
    var speechBargeInAvailable: Bool { false }
    func pauseReplyPlayback() {}
    func resumeReplyPlayback() {}
    func discardReplyPlayback() {}
    var hasReplyAudioLeft: Bool { true }
    var isReplyAudioPlaying: Bool { false }
    func waitUntilReplyDrained() async {}
    var recognizerIDs: String { "" }
}

/// The single voice state machine. The UI sends commands that return
/// immediately and observes `state` (or `states()`). Heavy pipeline work
/// runs strictly in order on one serialized queue, so a start never overlaps
/// a teardown, and generation tokens discard a start that a Stop superseded.
///
///     listening --utterance--> thinking --replyStarted--> speaking
///         ^                       |                      |      |
///         +-----replyFinished-----+----------------------+  speech over reply
///         |                                                     v
///         +------------- no / drained yes ------------ pausedAwaitingContinue
///     (yes resumes speaking; anything else is submitted as the next turn)
@MainActor
public final class VoiceSessionController: ObservableObject {
    @Published public private(set) var state: VoiceSessionState = .idle
    /// Quiet inline line above the composer after an interruption (incoming
    /// call) stopped voice. Cleared by the next mic tap or by leaving the chat.
    @Published public private(set) var interruptionNotice: String?
    /// Receives each spoken turn of the current session, once. The UI submits
    /// it through the same path as a typed turn and returns whether the
    /// submit point took it; a refusal returns the session to listening.
    public var onTurn: (@MainActor (VoiceUtterance) -> Bool)?
    /// Failure sink: message and whether Retry makes sense. The default shows
    /// the app-wide voice banner instead of an alert on a screen that may be gone.
    public var onFailure: (@MainActor (String, Bool) -> Void)?
    /// The paused reply was declined (No): the UI stops its generation.
    public var onReplyDiscarded: (@MainActor () -> Void)?
    /// False after `leave()` until the next `start()`.
    public private(set) var isAttached = true
    /// Teardowns queued or running. The mic button stays enabled meanwhile.
    public var isCleaningUp: Bool { pendingTeardowns > 0 }
    public var micLevel: Double { state == .listening ? backend.micLevel : 0 }

    private let backend: VoicePipelineBackend
    private var generation = 0
    /// Sessions whose backend start ran (or is running) and are not torn down.
    private var liveGenerations: Set<Int> = []
    private var pendingTeardowns = 0
    private var tail: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<VoiceSessionState>.Continuation] = [:]
    /// Last utterance id this controller handled, for logs.
    private var lastUtteranceID: Int?
    /// Bumped per drain wait so only the latest one acts.
    private var drainWait = 0
    /// The reply's run ended while the prompt was up: what's left is all
    /// there is, so a resume must wait for it to drain (no stuck .speaking).
    private var replyRunEnded = false

    public init(backend: VoicePipelineBackend) {
        self.backend = backend
        self.onFailure = { [weak self] message, canRetry in
            VoiceLibraryBannerCenter.shared.show(
                .voiceSessionFailed(message: message, canRetry: canRetry)
            ) { [weak self] in
                self?.start()
            }
        }
    }

    // MARK: Commands (all return immediately)

    /// Mic button: idle → start; anything active → stop.
    /// A tap while a previous session is still cleaning up queues the start.
    public func toggleMic() {
        if state.isActive { stop() } else { start() }
    }

    public func start() {
        interruptionNotice = nil
        guard !state.isActive else { return }
        isAttached = true
        generation += 1
        let session = generation
        setState(.starting)
        log("start", "cleaning=\(isCleaningUp)")
        enqueue { [weak self] in await self?.runStart(session) }
    }

    /// Stop button: audio cuts now, state is idle now, teardown runs later.
    public func stop() { end(reason: "stop", forceRelease: false) }

    /// Back out of the chat: same as Stop, and releases audio held by a
    /// spoken reply even when voice control was not on.
    public func leave() {
        isAttached = false
        interruptionNotice = nil
        end(reason: "leave", forceRelease: true)
    }

    /// App backgrounded with a teardown policy: same as `leave()` but stays attached.
    public func enterBackground() { end(reason: "background", forceRelease: true) }

    /// Audio-session interruption. Began: a Stop command (one teardown; the
    /// text reply keeps streaming). Ended: nothing, even with shouldResume —
    /// the user taps the mic again.
    public func handleInterruption(began: Bool, shouldResume: Bool) {
        let command = VoiceInterruptionPolicy.command(
            began: began,
            shouldResume: shouldResume,
            sessionActive: state.isActive
        )
        log("interruption", "began=\(began) resume=\(shouldResume) command=\(command.rawValue)")
        guard command == .stopSession else { return }
        end(reason: "interruption", forceRelease: false)
        interruptionNotice = VoiceInterruptionPolicy.pausedNotice
    }

    /// Captured when a turn is submitted: the reply may speak, or re-arm the
    /// pipeline, only while `isLive(sessionToken:)` still holds (req. 11).
    /// Nil when voice control is off.
    public var sessionToken: Int? { state.isActive ? generation : nil }

    /// False once that session ended (Stop, Back, background, interruption,
    /// error), even if a new session has started since.
    public func isLive(sessionToken token: Int) -> Bool {
        state.isActive && generation == token
    }

    /// A typed turn was submitted while voice control is on.
    public func turnStarted() {
        guard state == .listening || state == .speaking || state == .pausedAwaitingContinue else { return }
        if state == .pausedAwaitingContinue { backend.discardReplyPlayback() }
        transition(to: .thinking)
    }

    /// The reply's first audio is playing.
    public func replyStarted() {
        guard state == .thinking else { return }
        transition(to: .speaking)
    }

    /// The reply's run ended (played out, failed or was stopped). Listening
    /// resumes when playback actually finishes: audio still playing keeps the
    /// session speaking until it drains (req. 7, 15). While the prompt is up,
    /// the reply's audio is still waiting on the answer.
    public func replyFinished() {
        switch state {
        case .thinking, .speaking:
            guard backend.isReplyAudioPlaying else {
                transition(to: .listening)
                return
            }
            if state == .thinking { transition(to: .speaking) }
            listenWhenReplyDrains()
        case .pausedAwaitingContinue where !backend.hasReplyAudioLeft:
            backend.discardReplyPlayback()
            transition(to: .listening, listen: false) // keep hearing the answer
        case .pausedAwaitingContinue:
            replyRunEnded = true
            log("reply.ended.paused", ids)
        default:
            break
        }
    }

    /// Speaking with the run over: listen once the audio actually drains.
    private func listenWhenReplyDrains() {
        drainWait += 1
        let wait = drainWait
        let session = generation
        log("reply.draining", ids)
        Task { @MainActor [weak self] in
            await self?.backend.waitUntilReplyDrained()
            guard let self, self.generation == session, self.drainWait == wait,
                  self.state == .speaking else { return }
            self.transition(to: .listening)
        }
    }

    /// The app went inactive or came back: the mic follows while listening.
    public func setSceneActive(_ active: Bool) {
        guard state == .listening else { return }
        backend.setListenMode(active ? .listening : .off)
    }

    /// Yes / No buttons on the "Would you like me to continue?" prompt.
    public func answerContinue(_ yes: Bool) {
        guard state == .pausedAwaitingContinue else { return }
        _ = resolvePausedTurn(yes ? .yes : .no, source: "tap")
    }

    // MARK: Events from the recognizer

    private func handle(_ event: VoiceInputEvent) {
        switch event {
        case .speechOverReply:
            guard state == .speaking else {
                // Not ours to act on: put the recognizer back where this state wants it.
                backend.setListenMode(listenMode(for: state))
                return
            }
            // Barge-in never submits: pause, ask, and keep listening for the answer.
            backend.pauseReplyPlayback()
            transition(to: .pausedAwaitingContinue)
        case .utterance(let utterance):
            lastUtteranceID = utterance.id
            submit(utterance)
        case .recognizerFailed(let message):
            fail(message)
        }
    }

    /// The recognizer gave up: error state with a message, pipeline torn down.
    private func fail(_ message: String) {
        guard state.isActive else { return }
        let session = generation
        backend.silenceImmediately()
        generation += 1
        setState(.error(message))
        log("failed", "\(message) \(ids)")
        pendingTeardowns += 1
        enqueue { [weak self] in
            guard let self else { return }
            await self.teardownIfLive(session)
            self.pendingTeardowns -= 1
        }
        onFailure?(message, isAttached)
    }

    /// Every spoken turn and every spoken prompt answer comes through here.
    private func submit(_ utterance: VoiceUtterance) {
        guard state == .listening || state == .pausedAwaitingContinue else {
            log("utterance.dropped", "utt=\(utterance.id) state=\(state) \(backend.recognizerIDs)")
            return
        }
        if state == .pausedAwaitingContinue,
           resolvePausedTurn(VoiceContinuePromptPolicy.classify(utterance.text), source: "voice") {
            return
        }
        log("turn", "utt=\(utterance.id) chars=\(utterance.text.count) \(backend.recognizerIDs)")
        transition(to: .thinking)
        if let onTurn, !onTurn(utterance) {
            log("turn.refused", "utt=\(utterance.id)")
            if state == .thinking { transition(to: .listening) }
        }
    }

    /// The continue prompt, decided in one place for spoken and tapped
    /// answers. Yes resumes, no ends the reply, anything else drops the
    /// paused reply and is the next turn. Returns true when it consumed the answer.
    private func resolvePausedTurn(_ answer: VoiceContinueIntent, source: String) -> Bool {
        log("prompt.\(answer)", "\(source) \(ids)")
        switch answer {
        case .hold:
            // Stay paused with the prompt up; hear the next answer fresh.
            backend.setListenMode(.listening)
        case .yes where backend.hasReplyAudioLeft:
            backend.resumeReplyPlayback()
            transition(to: .speaking)
            if replyRunEnded { listenWhenReplyDrains() }
        case .yes:
            backend.discardReplyPlayback() // clears the pause; nothing left to play
            transition(to: .listening)
        case .no:
            backend.discardReplyPlayback()
            transition(to: .listening)
            onReplyDiscarded?()
        case .other:
            backend.discardReplyPlayback()
            return false
        }
        return true
    }

    /// Awaits every queued pipeline operation (tests, diagnostics).
    public func waitUntilSettled() async {
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    /// State stream: yields the current state, then every transition.
    public func states() -> AsyncStream<VoiceSessionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    // MARK: Pipeline operations (serialized)

    private func runStart(_ session: Int) async {
        guard session == generation else { return } // superseded before it ran
        liveGenerations.insert(session)
        do {
            try await backend.startPipeline(onEvent: { [weak self] event in
                guard let self, self.generation == session, self.state.isActive else { return }
                self.handle(event)
            })
        } catch {
            guard session == generation else { return } // Stop already queued its teardown
            let message = error.localizedDescription
            generation += 1
            setState(.error(message))
            log("failed", message)
            await teardownIfLive(session)
            onFailure?(message, isAttached)
            return
        }
        if session == generation {
            transition(to: .listening)
        }
        // Otherwise Stop arrived mid-start: its teardown is next in the queue
        // and closes the mic this start just opened.
    }

    private func end(reason: String, forceRelease: Bool) {
        let session = generation
        let wasActive = state.isActive
        let releaseIdleAudio = forceRelease && !wasActive && pendingTeardowns == 0 && backend.hasLiveAudio
        guard wasActive || releaseIdleAudio || state != .idle else { return }
        backend.silenceImmediately()
        if wasActive { generation += 1 } // invalidates an in-flight start
        if state != .idle { setState(.idle) }
        guard wasActive || releaseIdleAudio else { return }
        log(reason, "gen=\(session)")
        pendingTeardowns += 1
        enqueue { [weak self] in
            guard let self else { return }
            if wasActive {
                await self.teardownIfLive(session)
            } else {
                await self.backend.teardownPipeline()
            }
            self.pendingTeardowns -= 1
        }
    }

    private func teardownIfLive(_ session: Int) async {
        guard liveGenerations.remove(session) != nil else { return }
        await backend.teardownPipeline()
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// A state change plus the listening mode that goes with it. Listening
    /// and watching always start a fresh pass with a new utterance id.
    private func transition(to new: VoiceSessionState, listen: Bool = true) {
        let old = state
        setState(new)
        if listen { backend.setListenMode(listenMode(for: new)) }
        log("state", "\(old)->\(new) \(ids)")
    }

    private func listenMode(for state: VoiceSessionState) -> VoiceListenMode {
        switch state {
        case .listening, .pausedAwaitingContinue:
            return .listening
        case .speaking:
            // No echo cancellation (HFP, or the engine's check failed): mic closed.
            return backend.speechBargeInAvailable ? .watchingForBargeIn : .off
        default:
            return .off
        }
    }

    /// Utterance and pass ids for every state/turn log line (req. 13).
    private var ids: String {
        let pass = backend.recognizerIDs
        return pass.isEmpty ? "utt=\(lastUtteranceID.map(String.init) ?? "-") pass=-" : pass
    }

    private func log(_ event: String, _ detail: String) {
        VoiceAudioDebugStore.append(event: "voice.session.\(event)", detail: "gen=\(generation) \(detail)")
    }

    private func setState(_ new: VoiceSessionState) {
        if new == .thinking || !new.isActive { replyRunEnded = false }
        guard state != new else { return }
        state = new
        for continuation in continuations.values { continuation.yield(new) }
    }
}

/// One controller per voice service, app-wide, so cleanup outlives the chat
/// screen that started it.
@MainActor
public enum VoiceSessionControllers {
    private static var controllers: [ObjectIdentifier: VoiceSessionController] = [:]

    public static func controller(for voice: any VoiceServiceProtocol) -> VoiceSessionController {
        let key = ObjectIdentifier(voice)
        if let existing = controllers[key] { return existing }
        let created = VoiceSessionController(backend: VoiceServicePipelineBackend(voice: voice))
        controllers[key] = created
        return created
    }

    /// Routes an AVAudioSession interruption to every controller. Returns
    /// true when an active voice session took it (and is stopping).
    @discardableResult
    static func routeInterruption(userInfo: [AnyHashable: Any]?) -> Bool {
        #if os(iOS)
        guard let info = userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return false }
        let began = type == .began
        let options = AVAudioSession.InterruptionOptions(
            rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        )
        var handled = false
        for controller in controllers.values {
            if began, controller.state.isActive { handled = true }
            controller.handleInterruption(began: began, shouldResume: options.contains(.shouldResume))
        }
        return handled
        #else
        return false
        #endif
    }

    static func registerForTesting(_ controller: VoiceSessionController) {
        controllers[ObjectIdentifier(controller)] = controller
    }

    static func unregisterForTesting(_ controller: VoiceSessionController) {
        controllers[ObjectIdentifier(controller)] = nil
    }
}

/// Real pipeline: the voice service's recognizer plus the shared duplex engine.
@MainActor
final class VoiceServicePipelineBackend: VoicePipelineBackend {
    private let voice: any VoiceServiceProtocol

    init(voice: any VoiceServiceProtocol) {
        self.voice = voice
    }

    func startPipeline(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        if VoiceConnectionPolicy.shouldWarm(voiceOutputEnabled: true, trigger: .microphoneOpened) {
            await voice.prepareSpokenConversation()
        }
        try await voice.beginContinuousListening(onEvent: onEvent)
        voice.setVoiceControlArmed(true)
    }

    func setListenMode(_ mode: VoiceListenMode) { voice.setListenMode(mode) }

    func silenceImmediately() {
        voice.setListenMode(.off)
        voice.setVoiceControlArmed(false)
        voice.silenceNow()
    }

    func teardownPipeline() async {
        if VoiceConnectionPolicy.shouldClose(voiceOutputEnabled: false, reason: .voiceToggledOff) {
            await voice.endSpokenConversationAsync()
        } else {
            voice.endContinuousListening()
        }
    }

    var micLevel: Double { voice.currentMicLevel }
    var hasLiveAudio: Bool { voice.hasLiveAudio }
    var speechBargeInAvailable: Bool { voice.isSpeechBargeInEnabled }

    func pauseReplyPlayback() { VoiceDuplexEngine.shared.pausePlayback() }
    func resumeReplyPlayback() { VoiceDuplexEngine.shared.resumePlayback() }

    func discardReplyPlayback() {
        voice.cancelSpeech() // stops the TTS stream so no late audio follows
        VoiceDuplexEngine.shared.stopPlayback()
    }

    var hasReplyAudioLeft: Bool { VoiceDuplexEngine.shared.hasPendingPlayback }
    var isReplyAudioPlaying: Bool { VoiceDuplexEngine.shared.isPlayingBack }
    func waitUntilReplyDrained() async { await VoiceDuplexEngine.shared.waitUntilFinished() }
    var recognizerIDs: String { voice.listenIDs }
}
