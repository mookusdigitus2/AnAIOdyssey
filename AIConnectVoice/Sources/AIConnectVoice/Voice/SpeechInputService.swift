// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation
import Speech
import AIModelOptions

/// What the recognizer owner reports to the session controller.
public enum VoiceInputEvent: Equatable, Sendable {
    /// 1.5 s of silence ended an utterance. The only way a turn is spoken.
    case utterance(VoiceUtterance)
    /// The user spoke over a playing reply (`.watchingForBargeIn` only, at
    /// least `VoiceBargeInPolicy.minimumWords`). Never a turn: the controller
    /// pauses the reply and asks. The same live pass keeps listening under a
    /// new utterance id, so the words already heard lead the answer.
    case speechOverReply
    /// The recognizer kept failing; listening stopped (req. 12).
    case recognizerFailed(String)
}

/// Time source for the debounce and the recovery backoff. Tests use a fake.
public protocol VoiceClock: AnyObject, Sendable {
    var now: TimeInterval { get }
}

public final class SystemVoiceClock: VoiceClock {
    public static let shared = SystemVoiceClock()
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// What the mic gate needs to know about playback, route and echo cancellation.
struct VoiceMicConditions {
    var replyPlaying: Bool
    var echoCancelled: Bool
    var roomTailQuiet: Bool
}

/// The one owner of continuous speech recognition (Apple Speech, on-device
/// where supported) on the shared duplex engine's mic. One recognition pass
/// is live at a time; results from any other pass are dropped. The caller
/// picks the mode; after each utterance the mode drops to `.off` until the
/// caller decides what comes next.
@MainActor
public final class SystemSpeechInputService: NSObject {
    /// Live transcript of the current utterance as the recognizer revises it.
    public var onPartialTranscript: (@MainActor (String) -> Void)?
    public private(set) var mode: VoiceListenMode = .off

    private let speechRecognizer = SFSpeechRecognizer()
    private var onEvent: (@MainActor (VoiceInputEvent) -> Void)?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Recognition passes are numbered; only the live one may report results.
    private var passCounter = 0
    private var livePassID: Int?
    /// Unique across instances, so a submitted id is never reused.
    private static var utteranceCounter = 0
    private var utteranceID = 0
    /// Words heard before a recovery restarted the pass; they lead the next text.
    private var carriedText = ""
    private var latestTranscript = ""
    private var lastTranscriptChangeAt: TimeInterval = 0
    private var silenceMonitorTask: Task<Void, Never>?
    private let clock: VoiceClock
    /// Consecutive quick recognizer failures, and when the backoff ends.
    private var consecutiveFailures = 0
    private var restartAt: TimeInterval?
    private var passStartedAt: TimeInterval = 0
    /// Tests replace the engine's playback/route/AEC state with a fake.
    var micConditionsForTesting: (() -> VoiceMicConditions)?
    private let silenceDuration: TimeInterval = 1.5
    private let speechRMSThreshold: Float = 0.012

    /// Read and written on the audio tap thread as well as main.
    private let lock = NSLock()
    private nonisolated(unsafe) var lastAudioActivityUptime: TimeInterval = 0
    private nonisolated(unsafe) var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    /// False only in tests: no microphone, audio session or Apple recognizer.
    private let usesHardware: Bool

    public override init() {
        usesHardware = true
        clock = SystemVoiceClock.shared
        super.init()
    }

    init(hardwareFreeForTesting: Bool, clock: VoiceClock = SystemVoiceClock.shared) {
        usesHardware = !hardwareFreeForTesting
        self.clock = clock
        super.init()
    }

    /// Reflects the current Apple Speech recognizer capability. Permissions are
    /// requested when listening begins, so first use can still prompt the user.
    public var supportsLiveInput: Bool {
        speechRecognizer?.isAvailable == true
    }

    public var isListening: Bool { mode == .listening }

    public func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        #if os(iOS)
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
        #elseif os(macOS)
        let micOK = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        return speechOK && micOK
        #else
        return speechOK
        #endif
    }

    /// Opens the mic and starts listening. Events arrive on the main actor.
    public func beginContinuousListening(onEvent: @escaping @MainActor (VoiceInputEvent) -> Void) async throws {
        endContinuousListening(releaseSession: false)
        if usesHardware {
            guard await requestAuthorization() else {
                throw VoiceServiceError.synthesisFailed("Microphone or speech recognition permission was denied.")
            }
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                throw VoiceServiceError.notSupported
            }
            speechRecognizer.queue = .main
            try await openMic()
        }
        self.onEvent = onEvent
        setMode(.listening)
    }

    /// Text-only callers (not on the session controller).
    /// The mic goes quiet after each utterance; with `relistenAfterEachUtterance`
    /// it re-arms on a fresh pass right after delivering it, otherwise it stays
    /// quiet until `setMode(.listening)`.
    public func beginContinuousListening(relistenAfterEachUtterance: Bool = false,
                                         onUtterance: @escaping @MainActor (String) -> Void) async throws {
        try await beginContinuousListening(onEvent: { [weak self] event in
            guard case .utterance(let utterance) = event else { return }
            onUtterance(utterance.text)
            if relistenAfterEachUtterance { self?.setMode(.listening) }
        })
    }

    public func endContinuousListening() {
        endContinuousListening(releaseSession: true)
    }

    /// `releaseSession: false` stops recognition without `setActive(false)`:
    /// deactivating while the engine still runs fails ("session busy") and
    /// other apps' audio never resumes.
    func endContinuousListening(releaseSession: Bool) {
        let wasOpen = onEvent != nil
        onEvent = nil
        setModeUnchecked(.off)
        VoiceDuplexEngine.shared.onMicBuffer = nil
        VoiceDuplexEngine.shared.onGraphRebuilt = nil
        #if os(iOS)
        if wasOpen, releaseSession, usesHardware {
            VoiceAudioSession.deactivate()
        }
        #endif
    }

    /// The single listening switch. `.listening` and `.watchingForBargeIn`
    /// start a fresh pass with a new utterance id; `.off` stops it.
    public func setMode(_ new: VoiceListenMode) {
        guard onEvent != nil, new != mode else { return }
        setModeUnchecked(new)
    }

    private func setModeUnchecked(_ new: VoiceListenMode) {
        let old = mode
        mode = new
        stopPass()
        carriedText = ""
        restartAt = nil
        if new == .off { consecutiveFailures = 0 } else { startPass() }
        if old != new {
            VoiceAudioDebugStore.append(event: "listen.mode", detail: "\(old.rawValue)->\(new.rawValue) \(ids)")
        }
    }

    private var ids: String { currentIDs }

    /// "utt=<id> pass=<id or ->" for the session controller's logs (req. 13).
    public var currentIDs: String { "utt=\(utteranceID) pass=\(livePassID.map(String.init) ?? "-")" }

    private func openMic() async throws {
        VoiceDuplexEngine.shared.onMicBuffer = { [weak self] buffer in
            self?.handleMicBuffer(buffer)
        }
        VoiceDuplexEngine.shared.onGraphRebuilt = { [weak self] in
            self?.recover(reason: "graph")
        }
        #if os(iOS)
        do {
            try await VoiceAudioSession.activateForSpokenConversationAsync()
            try await VoiceAudioSession.prepareForRecordingAsync()
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            throw error
        }
        #endif
        do {
            try await VoiceDuplexEngine.shared.prepareAsync(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.graphRebuildFailed)
            throw error
        }
        await VoiceDuplexEngine.shared.ensureCaptureReady(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
    }

    /// Route change, interruption or recognizer error: a fresh pass with a
    /// new utterance id. Words already heard lead the new utterance, so the
    /// turn is neither lost nor delivered twice.
    private func recover(reason: String) {
        guard mode != .off else { return }
        let heard = currentText
        stopPass()
        carriedText = mode == .listening ? heard : ""
        startPass()
        VoiceAudioDebugStore.append(event: "listen.recover", detail: "\(reason) \(ids) carried=\(carriedText.count)")
    }

    /// A recognizer error: retry with backoff, give up after the cap.
    private func recoverFromFailure(_ error: String) {
        guard mode != .off else { return }
        if clock.now - passStartedAt >= VoiceRecoveryPolicy.healthyPassSeconds { consecutiveFailures = 0 }
        consecutiveFailures += 1
        if VoiceRecoveryPolicy.shouldGiveUp(afterFailures: consecutiveFailures) {
            VoiceAudioDebugStore.append(event: "listen.failed", detail: "\(ids) failures=\(consecutiveFailures) \(error)")
            let handler = onEvent
            setModeUnchecked(.off)
            handler?(.recognizerFailed(VoiceRecoveryPolicy.failureMessage))
            return
        }
        let delay = VoiceRecoveryPolicy.retryDelay(afterFailures: consecutiveFailures)
        guard delay > 0 else {
            recover(reason: "error")
            return
        }
        let heard = currentText
        stopPass()
        carriedText = mode == .listening ? heard : ""
        restartAt = clock.now + delay
        VoiceAudioDebugStore.append(event: "listen.backoff", detail: "\(ids) failures=\(consecutiveFailures) delay=\(delay)")
        startMonitor()
    }

    private func restartIfDue() {
        guard let due = restartAt, clock.now >= due, mode != .off else { return }
        restartAt = nil
        let carried = carriedText
        startPass()
        carriedText = carried
        VoiceAudioDebugStore.append(event: "listen.recover", detail: "backoff \(ids) carried=\(carriedText.count)")
    }

    private func startPass() {
        Self.utteranceCounter += 1
        utteranceID = Self.utteranceCounter
        latestTranscript = ""
        lastTranscriptChangeAt = clock.now
        passStartedAt = clock.now
        markAudioActivity()
        passCounter += 1
        let pass = passCounter
        livePassID = pass
        startMonitor()
        guard usesHardware, let speechRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        lock.withLock { activeRequest = request }
        // The recognizer calls back on `queue`, set to main above.
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { "\($0)" }
            MainActor.assumeIsolated {
                self?.handleRecognition(pass: pass, text: text, isFinal: isFinal, error: failure)
            }
        }
    }

    private func stopPass() {
        livePassID = nil
        lock.withLock {
            activeRequest?.endAudio()
            activeRequest = nil
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        latestTranscript = ""
    }

    /// Echo is handled by voice processing plus playback state only.
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard micFeedsRecognizer else { return }
        lock.withLock { activeRequest }?.append(buffer)
        if Self.rmsLevel(buffer: buffer) > speechRMSThreshold {
            markAudioActivity()
        }
    }

    /// The mic gate: playback state, route and the engine's verified echo
    /// cancellation decide; the transcript never does.
    private var micFeedsRecognizer: Bool {
        let conditions = micConditionsForTesting?() ?? {
            let engine = VoiceDuplexEngine.shared
            return VoiceMicConditions(
                replyPlaying: engine.isPlayingBack,
                echoCancelled: VoiceRouteMonitor.speechBargeInEnabled,
                roomTailQuiet: engine.micAcceptsSpeech
            )
        }()
        return livePassID != nil && VoiceListenGate.feedsRecognizer(
            mode: mode,
            replyPlaying: conditions.replyPlaying,
            echoCancelled: conditions.echoCancelled,
            roomTailQuiet: conditions.roomTailQuiet
        )
    }

    /// One recognizer callback. A stopped pass keeps calling back: Apple
    /// delivers its final result (and a cancel error) after `cancel()`,
    /// often a second later. Only the live pass counts.
    private func handleRecognition(pass: Int, text: String?, isFinal: Bool, error: String?) {
        guard pass == livePassID else {
            if isFinal || error != nil {
                VoiceAudioDebugStore.append(event: "recognition.stale", detail: "pass=\(pass) live=\(ids) final=\(isFinal)")
            }
            return
        }
        if let text, text != latestTranscript {
            latestTranscript = text
            lastTranscriptChangeAt = clock.now
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { consecutiveFailures = 0 }
            let heard = currentText
            if mode == .watchingForBargeIn, VoiceBargeInPolicy.shouldPause(heard: heard) {
                // Keep this pass and its words; they start a new utterance
                // that the 1.5 s debounce submits as the prompt's answer.
                Self.utteranceCounter += 1
                utteranceID = Self.utteranceCounter
                mode = .listening
                markAudioActivity()
                VoiceAudioDebugStore.append(event: "listen.speechOverReply", detail: "\(ids) words=\(heard.split(separator: " ").count)")
                VoiceAudioDebugStore.append(event: "listen.mode", detail: "watchingForBargeIn->listening \(ids)")
                onEvent?(.speechOverReply)
                guard pass == livePassID else { return }
            }
            if mode == .listening, !heard.isEmpty { onPartialTranscript?(heard) }
        }
        if let error {
            VoiceAudioDebugStore.append(event: "recognition.error", detail: "\(ids) \(error)")
            recoverFromFailure(error)
        } else if isFinal {
            // Apple ended the live pass on its own: keep listening on a fresh
            // pass; the words heard so far lead it (req. 12).
            recover(reason: "final")
        }
    }

    private var currentText: String {
        [carriedText, latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One 100 ms tick while the mic is on: the debounce and a due restart.
    private func startMonitor() {
        // Tests tick themselves (`tickForTesting()`) on a fake clock.
        guard usesHardware, silenceMonitorTask == nil else { return }
        silenceMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                guard self.mode != .off else {
                    self.silenceMonitorTask = nil
                    return
                }
                self.tick()
            }
        }
    }

    private func tick() {
        restartIfDue()
        checkEndpoint(requireSilence: true)
    }

    /// The only endpoint: 1.5 s with no new words and no voice ends the utterance.
    private func checkEndpoint(requireSilence: Bool) {
        guard mode == .listening, livePassID != nil, let onEvent else { return }
        let text = currentText
        guard !text.isEmpty else { return }
        if requireSilence {
            let transcriptQuiet = clock.now - lastTranscriptChangeAt >= silenceDuration
            let audioQuiet = audioQuietDuration >= silenceDuration
            guard transcriptQuiet && audioQuiet else { return }
        }
        let utterance = VoiceUtterance(id: utteranceID, text: text)
        VoiceAudioDebugStore.append(event: "listen.utterance", detail: "\(ids) chars=\(text.count)")
        setModeUnchecked(.off)
        if usesHardware { VoiceListeningCue.play() }
        onEvent(.utterance(utterance))
    }

    private var audioQuietDuration: TimeInterval {
        clock.now - lock.withLock { lastAudioActivityUptime }
    }

    nonisolated private func markAudioActivity() {
        let now = clock.now
        lock.withLock { lastAudioActivityUptime = now }
    }

    nonisolated private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<frameLength {
            sum += samples[index] * samples[index]
        }
        return sqrt(sum / Float(frameLength))
    }
}

// MARK: - Test hooks (hardware-free instances only)

extension SystemSpeechInputService {
    var livePassIDForTesting: Int? { livePassID }
    var utteranceIDForTesting: Int { utteranceID }

    /// A recognizer callback for `pass`, as `SFSpeechRecognitionTask` would deliver it.
    func receiveRecognitionForTesting(pass: Int, text: String, isFinal: Bool) {
        handleRecognition(pass: pass, text: text, isFinal: isFinal, error: nil)
    }

    /// The recognizer failing `pass`.
    func failRecognitionForTesting(pass: Int) {
        handleRecognition(pass: pass, text: nil, isFinal: true, error: "test failure")
    }

    /// The 100 ms monitor tick (debounce check and backoff restart).
    func tickForTesting() { tick() }

    /// A loud mic buffer arriving now. Returns whether it reached the recognizer.
    @discardableResult
    func feedMicForTesting(loud: Bool = true) -> Bool {
        guard micFeedsRecognizer else { return false }
        if loud { markAudioActivity() }
        return true
    }

    var consecutiveFailuresForTesting: Int { consecutiveFailures }
    var isBackingOffForTesting: Bool { restartAt != nil }

    /// The silence timer firing: the current utterance is complete.
    func endpointForTesting() {
        checkEndpoint(requireSilence: false)
    }

    /// A route change or interruption rebuilding the recognition pass.
    func restartRecognizerForTesting() {
        recover(reason: "test")
    }
}
