// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AVFoundation
import AIModelOptions

public enum VoiceServiceError: Error, LocalizedError {
    case notConfigured
    case notSupported
    case synthesisFailed(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Voice provider is not configured."
        case .notSupported: return "Voice feature is not supported on this platform."
        case .synthesisFailed(let msg): return msg
        case .recognitionFailed(let msg): return msg
        }
    }
}

/// One finished spoken utterance. `id` is unique app-wide, so the same
/// words delivered twice are recognisably one turn.
public struct VoiceUtterance: Equatable, Sendable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// Text-to-speech for voice interaction (§16.8). Speech input is Apple
/// Speech only (`SystemSpeechInputService`); there is no server speech-to-text.
@MainActor
public protocol VoiceServiceProtocol: AnyObject {
    var providerName: String { get }
    var isAvailable: Bool { get }
    var isListening: Bool { get }
    var supportsLiveInput: Bool { get }
    /// Recognizer may interrupt TTS on this route (headphones / speaker+AEC).
    var isSpeechBargeInEnabled: Bool { get }
    /// Last non-fatal audio recovery message (route change, HFP, session).
    var lastAudioIssue: String? { get }
    func setAudioIssueHandler(_ handler: (@MainActor (String?) -> Void)?)
    /// Voice-control mode lives on the service so a view rebuild cannot drop it.
    var isVoiceControlArmed: Bool { get }
    func setVoiceControlArmed(_ armed: Bool)
    func speak(text: String) async throws
    /// Starts a progressive TTS session for LLM token streaming.
    func beginStreamingSpeech()
    /// Feeds the cumulative assistant transcript so far; providers speak new content as it becomes ready.
    func appendStreamingSpeech(_ cumulativeText: String)
    /// Speaks any buffered remainder without ending the session (e.g. before an agent tool round).
    func checkpointStreamingSpeech(_ cumulativeText: String)
    /// Flushes remaining text and waits until streamed speech finishes.
    func finishStreamingSpeech(_ cumulativeText: String) async throws
    /// Stops speech immediately and clears any streaming TTS queue.
    func cancelSpeech()
    /// Pre-warms DNS/TLS/HTTP2, TTS sockets, the audio session, and local voices.
    func prepareSpokenConversation() async
    /// Closes warm sockets and releases the audio session.
    func endSpokenConversation()
    /// Ends the conversation with the heavy audio teardown (engine stop, tap
    /// removal, session deactivation) off the main thread, exactly once.
    func endSpokenConversationAsync() async
    /// Instant stop for the Stop/Back tap: playback cut and mic buffers ignored,
    /// synchronously and cheaply. The pipeline itself is torn down later.
    func silenceNow()
    /// Latest mic RMS (0 when not capturing), for the listening level ring.
    var currentMicLevel: Double { get }
    /// True while the engine or audio session is still held.
    var hasLiveAudio: Bool { get }
    /// Soft tone played the moment listening ends.
    func playListeningEndedCue()
    func setPlaybackStartedHandler(_ handler: (@MainActor () -> Void)?)
    func beginSpokenTurn()
    func markSpokenTurn(_ mark: VoiceLatencyMark)
    func endSpokenTurn() -> VoiceLatencyTrace?
    /// Opens the mic on the one recognizer (`SystemSpeechInputService`) and
    /// listens; each utterance and each barge-in arrives as an event.
    func beginContinuousListening(onEvent: @MainActor @escaping (VoiceInputEvent) -> Void) async throws
    /// The single listening switch, driven by the voice session controller.
    func setListenMode(_ mode: VoiceListenMode)
    /// The recognizer's current "utt=<id> pass=<id>", for session logs.
    var listenIDs: String { get }
    func endContinuousListening()
    /// Replays the last spoken reply from cached audio (no new synthesis).
    /// Returns false when nothing is cached for this provider.
    func replayLastReply() async -> Bool
}

public extension VoiceServiceProtocol {
    func replayLastReply() async -> Bool { false }
    var isListening: Bool { false }
    var supportsLiveInput: Bool { false }
    var isSpeechBargeInEnabled: Bool { false }
    var lastAudioIssue: String? { nil }
    func setAudioIssueHandler(_ handler: (@MainActor (String?) -> Void)?) {}
    var isVoiceControlArmed: Bool { false }
    func setVoiceControlArmed(_ armed: Bool) {}
    func beginStreamingSpeech() {}
    func appendStreamingSpeech(_ cumulativeText: String) {}
    func checkpointStreamingSpeech(_ cumulativeText: String) {}
    func finishStreamingSpeech(_ cumulativeText: String) async throws {}
    func cancelSpeech() {}
    func prepareSpokenConversation() async {}
    func endSpokenConversation() {}
    func endSpokenConversationAsync() async {
        endContinuousListening()
        endSpokenConversation()
    }
    func silenceNow() { cancelSpeech() }
    var currentMicLevel: Double { 0 }
    var hasLiveAudio: Bool { false }
    func playListeningEndedCue() { VoiceListeningCue.play() }
    func setPlaybackStartedHandler(_ handler: (@MainActor () -> Void)?) {}
    func beginSpokenTurn() {}
    func markSpokenTurn(_ mark: VoiceLatencyMark) {}
    func endSpokenTurn() -> VoiceLatencyTrace? { nil }
    func beginContinuousListening(onEvent: @MainActor @escaping (VoiceInputEvent) -> Void) async throws {
        throw VoiceServiceError.notSupported
    }
    func setListenMode(_ mode: VoiceListenMode) {}
    var listenIDs: String { "" }
    func endContinuousListening() {}
}

/// System fallback — uses platform speech APIs where available.
@MainActor
public final class SystemVoiceService: VoiceServiceProtocol {
    public let providerName = "System"
    public var isAvailable: Bool { true }

    private let speechInput = SystemSpeechInputService()
    private let speechOutput = AwaitableSpeechSynthesizer()
    private var segmenter = StreamingSpeechSegmenter()
    private var streamingActive = false

    private let voiceID: () -> String

    private var playbackStartedHandler: (@MainActor () -> Void)?
    private var didNotifyPlayback = false

    public init(voiceID: @escaping () -> String = { "" }) {
        self.voiceID = voiceID
        speechOutput.voiceIdentifier = voiceID
        speechOutput.onUtteranceStarted = { [weak self] in
            self?.notifyPlaybackStarted()
        }
    }

    public func prepareSpokenConversation() async {
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? await VoiceDuplexEngine.shared.prepareAsync(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        speechOutput.preloadVoice()
    }

    public func endSpokenConversation() {
        cancelSpeech()
        VoiceAudioSession.endSpokenConversation()
    }

    public func endSpokenConversationAsync() async {
        releaseSpokenResources(endListening: true)
        await VoiceAudioSession.endSpokenConversationAsync()
    }

    public func silenceNow() {
        VoiceDuplexEngine.shared.silenceNow()
        cancelSpeech()
    }

    public var currentMicLevel: Double { VoiceDuplexEngine.shared.currentMicRMS }
    public var hasLiveAudio: Bool {
        VoiceAudioSession.conversationActive || VoiceDuplexEngine.shared.isEngineRunning
    }

    /// Recognizer and speech output only; never touches the engine or session,
    /// so the composite can run one ordered teardown afterwards.
    public func releaseSpokenResources(endListening: Bool) {
        if endListening {
            speechInput.endContinuousListening(releaseSession: false)
        }
        cancelSpeech()
    }

    public func setPlaybackStartedHandler(_ handler: (@MainActor () -> Void)?) {
        playbackStartedHandler = handler
    }

    private func notifyPlaybackStarted() {
        guard !didNotifyPlayback else { return }
        didNotifyPlayback = true
        playbackStartedHandler?()
    }

    public var isListening: Bool { speechInput.isListening }
    public var supportsLiveInput: Bool { speechInput.supportsLiveInput }
    public var isSpeechBargeInEnabled: Bool { VoiceRouteMonitor.speechBargeInEnabled }
    public var lastAudioIssue: String? { VoiceDuplexEngine.shared.lastAudioIssue }

    public func setAudioIssueHandler(_ handler: (@MainActor (String?) -> Void)?) {
        VoiceDuplexEngine.shared.onAudioIssue = handler
    }

    public func beginContinuousListening(onEvent: @MainActor @escaping (VoiceInputEvent) -> Void) async throws {
        try await speechInput.beginContinuousListening(onEvent: onEvent)
    }

    public func setListenMode(_ mode: VoiceListenMode) {
        speechInput.setMode(mode)
    }

    public var listenIDs: String { speechInput.currentIDs }

    public func endContinuousListening() {
        speechInput.endContinuousListening()
    }

    public func speak(text: String) async throws {
        #if os(macOS) || os(iOS)
        guard let speakable = SpeechMarkdownSanitizer.speakable(text) else { return }
        try await speechOutput.speak(speakable)
        #else
        throw VoiceServiceError.notSupported
        #endif
    }

    public func beginStreamingSpeech() {
        speechOutput.stop()
        streamingActive = true
        didNotifyPlayback = false
        segmenter.reset()
    }

    public func appendStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        #if os(macOS) || os(iOS)
        let segments = segmenter.consume(cumulative: cumulativeText)
        for segment in segments {
            speechOutput.enqueue(segment)
        }
        #endif
    }

    public func checkpointStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        #if os(macOS) || os(iOS)
        let remaining = segmenter.finish(cumulative: cumulativeText)
        for segment in remaining {
            speechOutput.enqueue(segment)
        }
        segmenter.reset()
        #endif
    }

    public func finishStreamingSpeech(_ cumulativeText: String) async throws {
        guard streamingActive else { return }
        #if os(macOS) || os(iOS)
        let remaining = segmenter.finish(cumulative: cumulativeText)
        for segment in remaining {
            speechOutput.enqueue(segment)
        }
        await speechOutput.waitUntilFinished()
        #endif
        streamingActive = false
    }

    public func cancelSpeech() {
        streamingActive = false
        segmenter.reset()
        #if os(macOS) || os(iOS)
        speechOutput.stop()
        #endif
    }
}

/// ElevenLabs TTS (§16.8); speech input is always Apple Speech. Requires API key in Settings.
@MainActor
public final class ElevenLabsVoiceService: VoiceServiceProtocol {
    public let providerName = "ElevenLabs"
    private let apiKey: () -> String
    private let voiceID: () -> String
    private let modelID: () -> String
    private let playback = AudioPlaybackService()
    private let session: URLSession
    private let webSocketTTS: ElevenLabsWebSocketTTSClient

    /// HTTP fallback queue when the WebSocket path is unavailable.
    private var pendingSegments: [String] = []
    private var httpSegmenter = StreamingSpeechSegmenter()
    private var isSynthesizing = false
    private var streamingActive = false
    private var usingWebSocket = false
    private var isConnecting = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishRequested = false
    private var streamWaiters: [CheckedContinuation<Void, Error>] = []
    private var streamError: Error?
    /// Tail of the serialized streaming-TTS pipeline; each op awaits the
    /// previous one so text reaches the synthesizer strictly in call order.
    private var pipelineTask: Task<Void, Never>?
    /// Bumped on begin/cancel so ops queued for an older session become no-ops.
    private var speechGeneration = 0
    private var playbackStartedHandler: (@MainActor () -> Void)?
    private var didNotifyPlayback = false
    private var didNotifyFirstTTS = false

    public init(
        apiKey: @escaping () -> String,
        voiceID: @escaping () -> String,
        modelID: @escaping () -> String = { VoiceCatalog.defaultElevenLabsModelID },
        session: URLSession? = nil
    ) {
        let session = session ?? VoiceNetworkSession.shared
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.session = session
        self.webSocketTTS = ElevenLabsWebSocketTTSClient(session: session)
        self.webSocketTTS.onFirstAudio = { [weak self] in
            self?.notifyPlaybackStarted()
        }
        self.webSocketTTS.onFirstTextSent = { [weak self] in
            self?.didNotifyFirstTTS = true
        }
    }

    public func prepareSpokenConversation() async {
        guard isAvailable else { return }
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? await webSocketTTS.prepare(
            apiKey: apiKey(),
            voiceID: voiceID(),
            modelID: resolvedModelID()
        )
    }

    public func endSpokenConversation() {
        webSocketTTS.cancel()
        playback.stop()
        VoiceAudioSession.endSpokenConversation()
    }

    /// Closes the TTS socket (keep-alive, receive loop) without engine teardown.
    public func releaseSpokenResources() {
        cancelSpeech()
        webSocketTTS.cancel(teardownEngine: false)
        playback.stop()
    }

    public func setPlaybackStartedHandler(_ handler: (@MainActor () -> Void)?) {
        playbackStartedHandler = handler
    }

    private func notifyPlaybackStarted() {
        guard !didNotifyPlayback else { return }
        didNotifyPlayback = true
        playbackStartedHandler?()
    }

    public var isAvailable: Bool {
        !apiKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func listVoices(apiKey: String, session: URLSession = .shared) async throws -> [VoiceOption] {
        try await ElevenLabsAPIClient(apiKey: apiKey, session: session).listVoices()
    }

    public static func lookupVoice(
        apiKey: String,
        voiceID: String,
        session: URLSession = .shared
    ) async throws -> ElevenLabsVoiceLookup {
        try await ElevenLabsAPIClient(apiKey: apiKey, session: session).lookupVoice(voiceID: voiceID)
    }

    public static func addSharedVoice(
        apiKey: String,
        publicOwnerID: String,
        voiceID: String,
        name: String,
        session: URLSession = .shared
    ) async throws {
        try await ElevenLabsAPIClient(apiKey: apiKey, session: session).addSharedVoice(
            publicOwnerID: publicOwnerID,
            voiceID: voiceID,
            name: name
        )
    }

    public func speak(text: String) async throws {
        guard isAvailable else { throw VoiceServiceError.notConfigured }
        guard let speakable = SpeechMarkdownSanitizer.speakable(text) else { return }
        let client = ElevenLabsAPIClient(apiKey: apiKey(), session: session)
        let audio = try await client.synthesizeSpeech(text: speakable, voiceID: voiceID())
        try await playback.play(data: audio)
    }

    public func beginStreamingSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        pendingSegments.removeAll()
        isSynthesizing = false
        finishRequested = false
        streamError = nil
        didNotifyPlayback = false
        didNotifyFirstTTS = false
        httpSegmenter.reset()
        webSocketTTS.beginTurn()
        streamingActive = true
        usingWebSocket = webSocketTTS.isConnected
        let waiters = streamWaiters
        streamWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        enqueuePipelineOp { service in
            await service.ensureStreamingTransport()
        }
    }

    public func appendStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            await service.appendStreaming(cumulativeText)
        }
    }

    public func checkpointStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            await service.checkpointStreaming(cumulativeText)
        }
    }

    /// Chains streaming-TTS work so ops run strictly in submission order.
    ///
    /// Each append used to spawn an independent task, so a straggler could run
    /// after `finishStreamingSpeech` had already closed the session; it then
    /// fell into the HTTP fallback and re-synthesized the whole reply, leaving
    /// playback running long after the turn ended. Ops also capture the session
    /// generation so work from a cancelled or finished session is discarded.
    private func enqueuePipelineOp(_ op: @escaping @MainActor (ElevenLabsVoiceService) async -> Void) {
        let generation = speechGeneration
        let previous = pipelineTask
        pipelineTask = Task { [weak self] in
            await previous?.value
            guard let self, self.speechGeneration == generation else { return }
            await op(self)
        }
    }

    public func finishStreamingSpeech(_ cumulativeText: String) async throws {
        guard streamingActive else { return }
        let generation = speechGeneration
        // Run after every append/checkpoint that was queued before this finish;
        // calling into the transport directly here could overtake them.
        await pipelineTask?.value
        guard streamingActive, speechGeneration == generation else { return }
        finishRequested = true

        if usingWebSocket {
            do {
                try await webSocketTTS.finish(cumulative: cumulativeText)
                streamingActive = false
                return
            } catch {
                // Fall through to HTTP drain if the socket failed mid-stream.
                streamError = error
                failOverToHTTP()
            }
        }

        let remaining = httpSegmenter.finish(cumulative: cumulativeText)
        pendingSegments.append(contentsOf: remaining)
        if pendingSegments.isEmpty && !isSynthesizing {
            streamingActive = false
            try await playback.waitUntilFinished()
            if let streamError {
                let error = streamError
                self.streamError = nil
                throw error
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.streamWaiters.append(continuation)
            Task { await self.drainHTTPSynthesisQueue() }
        }
    }

    public func replayLastReply() async -> Bool {
        webSocketTTS.replayLastReply()
    }

    public func cancelSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        pendingSegments.removeAll()
        isSynthesizing = false
        streamingActive = false
        finishRequested = false
        isConnecting = false
        streamError = nil
        didNotifyPlayback = false
        httpSegmenter.reset()
        webSocketTTS.cancelPlaybackKeepingConnection()
        usingWebSocket = webSocketTTS.isConnected
        let connectionWaiters = connectionWaiters
        self.connectionWaiters.removeAll()
        for waiter in connectionWaiters {
            waiter.resume()
        }
        let waiters = streamWaiters
        streamWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        playback.stop()
    }

    // MARK: - Streaming internals

    private func ensureStreamingTransport() async {
        if usingWebSocket { return }
        if isConnecting {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.connectionWaiters.append(continuation)
            }
            return
        }
        guard streamingActive else { return }
        isConnecting = true
        defer {
            isConnecting = false
            let waiters = connectionWaiters
            connectionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        do {
            try await webSocketTTS.prepare(
                apiKey: apiKey(),
                voiceID: voiceID(),
                modelID: resolvedModelID()
            )
            if streamingActive || webSocketTTS.isConnected {
                usingWebSocket = true
            }
        } catch {
            // Keep HTTP sentence fallback available.
            usingWebSocket = false
        }
    }

    private func appendStreaming(_ cumulativeText: String) async {
        await ensureStreamingTransport()
        guard streamingActive else { return }
        if usingWebSocket {
            do {
                try await webSocketTTS.append(cumulative: cumulativeText)
                return
            } catch {
                // Continue with HTTP fallback for remaining text.
                failOverToHTTP()
            }
        }

        let segments = httpSegmenter.consume(cumulative: cumulativeText)
        guard !segments.isEmpty else { return }
        pendingSegments.append(contentsOf: segments)
        await drainHTTPSynthesisQueue()
    }

    private func checkpointStreaming(_ cumulativeText: String) async {
        await ensureStreamingTransport()
        guard streamingActive else { return }
        if usingWebSocket {
            do {
                try await webSocketTTS.checkpoint(cumulative: cumulativeText)
                return
            } catch {
                failOverToHTTP()
            }
        }

        let remaining = httpSegmenter.finish(cumulative: cumulativeText)
        pendingSegments.append(contentsOf: remaining)
        httpSegmenter.reset()
        await drainHTTPSynthesisQueue()
    }

    /// Switches from the WebSocket transport to HTTP sentence synthesis,
    /// marking the text the socket already synthesized as spoken so the
    /// fallback never replays the reply from the beginning.
    private func failOverToHTTP() {
        httpSegmenter.markSpoken(cumulative: webSocketTTS.spokenText)
        usingWebSocket = false
        webSocketTTS.cancel()
    }

    private func drainHTTPSynthesisQueue() async {
        guard !isSynthesizing else { return }
        isSynthesizing = true
        defer { isSynthesizing = false }

        while let segment = pendingSegments.first {
            pendingSegments.removeFirst()
            do {
                guard isAvailable else { throw VoiceServiceError.notConfigured }
                let client = ElevenLabsAPIClient(apiKey: apiKey(), session: session)
                let audio = try await client.synthesizeSpeech(
                    text: segment,
                    voiceID: voiceID(),
                    modelID: resolvedModelID()
                )
                playback.enqueue(data: audio)
            } catch {
                streamError = error
                pendingSegments.removeAll()
                break
            }
        }

        guard finishRequested, pendingSegments.isEmpty else { return }

        do {
            try await playback.waitUntilFinished()
            streamingActive = false
            let waiters = streamWaiters
            streamWaiters.removeAll()
            if let streamError {
                let error = streamError
                self.streamError = nil
                for waiter in waiters {
                    waiter.resume(throwing: error)
                }
            } else {
                for waiter in waiters {
                    waiter.resume()
                }
            }
        } catch {
            streamingActive = false
            let waiters = streamWaiters
            streamWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
        }
    }

    private func resolvedModelID() -> String {
        VoiceCatalog.resolvedModelID(modelID(), for: .elevenLabs)
    }
}

/// Apple Intelligence voice / on-device speech capabilities (§16.7 / §16.8).
@MainActor
public final class AppleIntelligenceService: ObservableObject {
    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var statusMessage: String = "Checking Apple Intelligence availability…"

    public init() {
        refreshAvailability()
    }

    public func refreshAvailability() {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            isAvailable = false
            statusMessage = "Apple Intelligence integration is investigational on this OS version. Use System or ElevenLabs voice for now."
        } else {
            isAvailable = false
            statusMessage = "Apple Intelligence requires iOS 18 or later."
        }
        #elseif os(macOS)
        if #available(macOS 15.0, *) {
            isAvailable = false
            statusMessage = "Apple Intelligence on Mac is investigational — extend here when App Intents / Writing Tools APIs are wired."
        } else {
            isAvailable = false
            statusMessage = "Apple Intelligence requires macOS 15 or later."
        }
        #else
        isAvailable = false
        statusMessage = "Not supported on this platform."
        #endif
    }
}

