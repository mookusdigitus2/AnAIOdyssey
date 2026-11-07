// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// Bidirectional xAI TTS WebSocket: sentences in as `text.delta`, PCM back as `audio.delta`.
@MainActor
final class XAITTSClient {
    private let session: URLSession
    private let player = PCMStreamPlayer(sampleRate: XAITTSCodec.sampleRate)
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var streamError: Error?
    private var awaitingAudioDone = false
    private var didReceiveAudioDone = false
    private var utteranceWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectedVoice = ""
    private var ignoreIncomingAudio = false
    var onFirstAudio: (() -> Void)?
    var onFirstTextSent: (() -> Void)?

    init(session: URLSession = VoiceNetworkSession.shared) {
        self.session = session
        player.onFirstBufferScheduled = { [weak self] in
            self?.onFirstAudio?()
        }
    }

    var isConnected: Bool { webSocket != nil }

    func prepare(apiKey: String, voiceID: String) async throws {
        try await connect(apiKey: apiKey, voiceID: voiceID)
        try player.prime()
    }

    func beginTurn() {
        ignoreIncomingAudio = false
        player.resetFirstScheduleFlag()
    }

    func cancelPlaybackKeepingConnection() {
        ignoreIncomingAudio = true
        player.stop(teardownEngine: false)
        awaitingAudioDone = false
        didReceiveAudioDone = false
        let waiters = utteranceWaiters
        utteranceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func connect(apiKey: String, voiceID: String) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw VoiceServiceError.notConfigured
        }
        let voice = VoiceCatalog.resolvedVoiceID(voiceID, for: .xai)
        if isConnected, connectedVoice == voice, streamError == nil {
            return
        }
        cancel()

        let url = try XAITTSCodec.webSocketURL(
            XAITTSCodec.ConnectionConfig(voice: voice, codec: "pcm", sampleRate: 24_000)
        )
        var request = URLRequest(url: url)
        request.setValue(XAITTSCodec.authorizationHeader(apiKey: trimmedKey), forHTTPHeaderField: "Authorization")

        let socket = session.webSocketTask(with: request)
        webSocket = socket
        connectedVoice = voice
        socket.resume()
        try player.prime()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendSentence(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onFirstTextSent?()
        try await sendJSON(XAITTSCodec.textDeltaMessage(trimmed))
        if let streamError { throw streamError }
    }

    /// Ends the current utterance so the server flushes remaining audio. Multiple
    /// utterances may share this connection after `audio.done`.
    func finishUtterance() async throws {
        guard webSocket != nil else { return }
        didReceiveAudioDone = false
        awaitingAudioDone = true
        try await sendJSON(XAITTSCodec.textDoneMessage())

        if !didReceiveAudioDone {
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.resumeUtteranceWaiters()
            }
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.utteranceWaiters.append(continuation)
            }
        }

        awaitingAudioDone = false
        await player.waitUntilFinished()
        if let streamError { throw streamError }
    }

    func cancel(teardownEngine: Bool = true) {
        receiveTask?.cancel()
        receiveTask = nil
        tearDownSocket()
        player.stop(teardownEngine: teardownEngine)
        connectedVoice = ""
        ignoreIncomingAudio = false
        awaitingAudioDone = false
        didReceiveAudioDone = false
        streamError = nil
        let waiters = utteranceWaiters
        utteranceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    nonisolated static func listVoices(apiKey: String, session: URLSession = .shared) async throws -> [VoiceOption] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VoiceServiceError.notConfigured }
        var request = URLRequest(url: try XAITTSCodec.voicesURL())
        request.setValue(XAITTSCodec.authorizationHeader(apiKey: trimmedKey), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceServiceError.synthesisFailed(detail)
        }
        return try XAITTSCodec.parseVoicesResponse(data)
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else {
            throw VoiceServiceError.synthesisFailed("xAI TTS stream is not connected.")
        }
        try await webSocket.send(.string(try VoiceJSON.encode(object)))
    }

    private func receiveLoop() async {
        guard let webSocket else { return }
        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    text = value
                @unknown default:
                    continue
                }
                handleMessage(text)
            } catch {
                if awaitingAudioDone && !didReceiveAudioDone {
                    streamError = error
                }
                resumeUtteranceWaiters()
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        switch XAITTSCodec.parseIncoming(text) {
        case .audioDelta(let pcm):
            if !ignoreIncomingAudio {
                player.schedule(pcmData: pcm)
            }
        case .audioDone:
            didReceiveAudioDone = true
            resumeUtteranceWaiters()
        case .audioClear:
            player.stop(teardownEngine: false)
            try? player.start()
            didReceiveAudioDone = true
            resumeUtteranceWaiters()
        case .error(let message):
            streamError = VoiceServiceError.synthesisFailed(message)
            resumeUtteranceWaiters()
        case .ignored:
            break
        }
    }

    private func resumeUtteranceWaiters() {
        let waiters = utteranceWaiters
        utteranceWaiters.removeAll()
        for waiter in waiters {
            if let streamError {
                waiter.resume(throwing: streamError)
            } else {
                waiter.resume()
            }
        }
    }

    private func tearDownSocket() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }
}
