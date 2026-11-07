// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// xAI TTS over one bidirectional WebSocket. Sentences go out as `text.delta`;
/// PCM comes back as `audio.delta` and starts playing before `text.done`.
@MainActor
public final class XAIVoiceService: VoiceServiceProtocol {
    public let providerName = "xAI"
    private let apiKey: () -> String
    private let voiceID: () -> String
    private let client: XAITTSClient

    private var segmenter = StreamingSpeechSegmenter()
    private var streamingActive = false
    private var didSendText = false
    private var pipelineTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var isConnecting = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var streamError: Error?
    private var playbackStartedHandler: (@MainActor () -> Void)?
    private var didNotifyPlayback = false

    public init(
        apiKey: @escaping () -> String,
        voiceID: @escaping () -> String,
        session: URLSession? = nil
    ) {
        let session = session ?? VoiceNetworkSession.shared
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.client = XAITTSClient(session: session)
        self.client.onFirstAudio = { [weak self] in
            self?.notifyPlaybackStarted()
        }
    }

    public func prepareSpokenConversation() async {
        guard isAvailable else { return }
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? await client.prepare(apiKey: apiKey(), voiceID: voiceID())
    }

    public func endSpokenConversation() {
        client.cancel()
        VoiceAudioSession.endSpokenConversation()
    }

    /// Closes the xAI socket without engine teardown.
    public func releaseSpokenResources() {
        cancelSpeech()
        client.cancel(teardownEngine: false)
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

    nonisolated public static func listVoices(apiKey: String, session: URLSession = .shared) async throws -> [VoiceOption] {
        try await XAITTSClient.listVoices(apiKey: apiKey, session: session)
    }

    public func speak(text: String) async throws {
        guard isAvailable else { throw VoiceServiceError.notConfigured }
        guard let speakable = SpeechMarkdownSanitizer.speakable(text) else { return }
        try await client.connect(apiKey: apiKey(), voiceID: voiceID())
        try await client.sendSentence(speakable)
        try await client.finishUtterance()
    }

    public func beginStreamingSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        didSendText = false
        streamError = nil
        didNotifyPlayback = false
        segmenter.reset()
        client.beginTurn()
        streamingActive = true
        enqueuePipelineOp { service in
            await service.ensureConnected()
        }
    }

    public func appendStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            await service.ensureConnected()
            guard service.streamingActive else { return }
            let segments = service.segmenter.consume(cumulative: cumulativeText)
            for segment in segments {
                try? await service.client.sendSentence(segment)
                service.didSendText = true
            }
        }
    }

    public func checkpointStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            await service.ensureConnected()
            guard service.streamingActive else { return }
            let remaining = service.segmenter.finish(cumulative: cumulativeText)
            for segment in remaining {
                try? await service.client.sendSentence(segment)
                service.didSendText = true
            }
            service.segmenter.reset()
            if service.didSendText {
                try? await service.client.finishUtterance()
                service.didSendText = false
            }
        }
    }

    public func finishStreamingSpeech(_ cumulativeText: String) async throws {
        guard streamingActive else { return }
        let generation = speechGeneration
        await pipelineTask?.value
        guard streamingActive, speechGeneration == generation else { return }
        await ensureConnected()
        guard streamingActive, speechGeneration == generation else { return }
        if let streamError {
            streamingActive = false
            throw streamError
        }
        let remaining = segmenter.finish(cumulative: cumulativeText)
        for segment in remaining {
            try await client.sendSentence(segment)
            didSendText = true
        }
        if didSendText {
            try await client.finishUtterance()
        }
        streamingActive = false
        didSendText = false
    }

    public func cancelSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        streamingActive = false
        didSendText = false
        isConnecting = false
        streamError = nil
        segmenter.reset()
        client.cancelPlaybackKeepingConnection()
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func enqueuePipelineOp(_ op: @escaping @MainActor (XAIVoiceService) async -> Void) {
        let generation = speechGeneration
        let previous = pipelineTask
        pipelineTask = Task { [weak self] in
            await previous?.value
            guard let self, self.speechGeneration == generation else { return }
            await op(self)
        }
    }

    private func ensureConnected() async {
        if client.isConnected { return }
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
            try await client.connect(apiKey: apiKey(), voiceID: voiceID())
            if !streamingActive {
                client.cancel()
            }
        } catch {
            streamError = error
        }
    }
}
