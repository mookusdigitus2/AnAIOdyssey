// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// OpenAI TTS: one streamed `POST /v1/audio/speech` per sentence, pipelined playback.
@MainActor
public final class OpenAIVoiceService: VoiceServiceProtocol {
    public let providerName = "OpenAI"
    private let apiKey: () -> String
    private let baseURL: () -> String
    private let modelID: () -> String
    private let voiceID: () -> String
    private let session: URLSession
    private let client: OpenAITTSClient

    private var segmenter = StreamingSpeechSegmenter()
    private var pendingSegments: [String] = []
    private var isSynthesizing = false
    private var streamingActive = false
    private var finishRequested = false
    private var streamError: Error?
    private var streamWaiters: [CheckedContinuation<Void, Error>] = []
    private var pipelineTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var playbackStartedHandler: (@MainActor () -> Void)?
    private var didNotifyPlayback = false

    public init(
        apiKey: @escaping () -> String,
        baseURL: @escaping () -> String,
        modelID: @escaping () -> String,
        voiceID: @escaping () -> String,
        session: URLSession? = nil
    ) {
        let session = session ?? VoiceNetworkSession.shared
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.voiceID = voiceID
        self.session = session
        self.client = OpenAITTSClient(session: session)
        self.client.onFirstAudio = { [weak self] in
            self?.notifyPlaybackStarted()
        }
    }

    public func prepareSpokenConversation() async {
        guard isAvailable else { return }
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        if let url = try? OpenAITTSCodec.speechURL(baseURL: baseURL()) {
            await VoiceNetworkSession.preconnect(urls: [VoiceConnectionPolicy.originURL(from: url.absoluteString)].compactMap { $0 })
        }
        try? client.prepare()
    }

    public func endSpokenConversation() {
        client.stop(teardownEngine: true)
        VoiceAudioSession.endSpokenConversation()
    }

    /// Stops this provider's playback without engine teardown.
    public func releaseSpokenResources() {
        cancelSpeech()
        client.stop(teardownEngine: false)
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

    public func speak(text: String) async throws {
        guard isAvailable else { throw VoiceServiceError.notConfigured }
        guard let speakable = SpeechMarkdownSanitizer.speakable(text) else { return }
        try await client.streamSentence(
            text: speakable,
            apiKey: apiKey(),
            baseURL: baseURL(),
            model: resolvedModel(),
            voice: resolvedVoice()
        )
        await client.waitUntilFinished()
    }

    public func beginStreamingSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        pendingSegments.removeAll()
        isSynthesizing = false
        finishRequested = false
        streamError = nil
        didNotifyPlayback = false
        segmenter.reset()
        client.beginTurn()
        streamingActive = true
    }

    public func appendStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            let segments = service.segmenter.consume(cumulative: cumulativeText)
            service.pendingSegments.append(contentsOf: segments)
            await service.drainSynthesisQueue()
        }
    }

    public func checkpointStreamingSpeech(_ cumulativeText: String) {
        guard streamingActive else { return }
        enqueuePipelineOp { service in
            guard service.streamingActive else { return }
            let remaining = service.segmenter.finish(cumulative: cumulativeText)
            service.pendingSegments.append(contentsOf: remaining)
            service.segmenter.reset()
            await service.drainSynthesisQueue()
        }
    }

    public func finishStreamingSpeech(_ cumulativeText: String) async throws {
        guard streamingActive else { return }
        let generation = speechGeneration
        await pipelineTask?.value
        guard streamingActive, speechGeneration == generation else { return }
        finishRequested = true
        let remaining = segmenter.finish(cumulative: cumulativeText)
        pendingSegments.append(contentsOf: remaining)
        if pendingSegments.isEmpty && !isSynthesizing {
            streamingActive = false
            await client.waitUntilFinished()
            if let streamError {
                let error = streamError
                self.streamError = nil
                throw error
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.streamWaiters.append(continuation)
            Task { await self.drainSynthesisQueue() }
        }
    }

    public func cancelSpeech() {
        speechGeneration += 1
        pipelineTask = nil
        pendingSegments.removeAll()
        isSynthesizing = false
        streamingActive = false
        finishRequested = false
        streamError = nil
        segmenter.reset()
        client.stop(teardownEngine: false)
        let waiters = streamWaiters
        streamWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func enqueuePipelineOp(_ op: @escaping @MainActor (OpenAIVoiceService) async -> Void) {
        let generation = speechGeneration
        let previous = pipelineTask
        pipelineTask = Task { [weak self] in
            await previous?.value
            guard let self, self.speechGeneration == generation else { return }
            await op(self)
        }
    }

    private func drainSynthesisQueue() async {
        guard !isSynthesizing else { return }
        isSynthesizing = true
        defer { isSynthesizing = false }

        while let segment = pendingSegments.first {
            pendingSegments.removeFirst()
            do {
                guard isAvailable else { throw VoiceServiceError.notConfigured }
                try await client.streamSentence(
                    text: segment,
                    apiKey: apiKey(),
                    baseURL: baseURL(),
                    model: resolvedModel(),
                    voice: resolvedVoice()
                )
            } catch {
                streamError = error
                pendingSegments.removeAll()
                break
            }
        }

        guard finishRequested, pendingSegments.isEmpty else { return }
        streamingActive = false
        await client.waitUntilFinished()
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
    }

    private func resolvedModel() -> String {
        VoiceCatalog.resolvedModelID(modelID(), for: .openai)
    }

    private func resolvedVoice() -> String {
        VoiceCatalog.resolvedVoiceID(voiceID(), for: .openai, modelID: resolvedModel())
    }
}
