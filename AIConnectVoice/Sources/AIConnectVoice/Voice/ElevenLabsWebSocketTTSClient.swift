// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// Streams text into ElevenLabs `/stream-input` and plays PCM audio as it arrives.
@MainActor
final class ElevenLabsWebSocketTTSClient {
    private let session: URLSession
    private let player = PCMStreamPlayer(sampleRate: ElevenLabsTTSCodec.sampleRate)
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sentText = ""
    private var segmenter = StreamingSpeechSegmenter()
    private var isFinished = false
    private var streamError: Error?
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []
    private var didReceiveFinal = false
    private var connectedVoiceID = ""
    private var connectedModelID = ""
    private var ignoreIncomingAudio = false
    private var replayCache = VoicePCMReplayCache(sampleRate: ElevenLabsTTSCodec.sampleRate)
    private var lastSendAt = Date()
    private var keepAliveTask: Task<Void, Never>?
    private var lastAPIKey = ""
    /// This turn's last text sent and last audio received (system uptime),
    /// so `finish` waits for audio still on the wire (req. 7, 15).
    private var lastTextSentAt: TimeInterval?
    private var lastAudioAt: TimeInterval?
    /// Last server close (code, reason) for diagnostics.
    private(set) var lastCloseDescription: String?

    var canReplayLastReply: Bool { replayCache.canReplay }

    var onFirstAudio: (() -> Void)?
    var onFirstTextSent: (() -> Void)?

    init(session: URLSession = VoiceNetworkSession.shared) {
        self.session = session
        player.onFirstBufferScheduled = { [weak self] in
            self?.onFirstAudio?()
        }
    }

    /// A task whose socket dropped ("Socket is not connected") is not reusable.
    var isConnected: Bool { webSocket?.state == .running }

    /// The cumulative text already handed to ElevenLabs for synthesis. The HTTP
    /// fallback uses this to skip audio this transport already produced.
    var spokenText: String { sentText }

    func prepare(apiKey: String, voiceID: String, modelID: String = "eleven_flash_v2_5") async throws {
        if isConnected, connectedVoiceID == voiceID, connectedModelID == modelID, streamError == nil {
            try player.prime()
            return
        }
        try await connect(apiKey: apiKey, voiceID: voiceID, modelID: modelID)
    }

    func connect(apiKey: String, voiceID: String, modelID: String = "eleven_flash_v2_5") async throws {
        if isConnected, connectedVoiceID == voiceID, connectedModelID == modelID, streamError == nil {
            try player.prime()
            resetTurnState()
            return
        }
        tearDownSocket()
        receiveTask?.cancel()
        receiveTask = nil

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsAPIError.notConfigured }
        lastAPIKey = trimmedKey

        let url = try ElevenLabsTTSCodec.streamInputURL(voiceID: voiceID, modelID: modelID)
        var request = URLRequest(url: url)
        request.setValue(trimmedKey, forHTTPHeaderField: "xi-api-key")

        let socket = session.webSocketTask(with: request)
        webSocket = socket
        connectedVoiceID = voiceID
        connectedModelID = modelID
        socket.resume()
        try player.prime()

        // Bootstrap voice settings + auth (also accepted via header above).
        try await sendJSON(ElevenLabsTTSCodec.bootstrapPayload(apiKey: trimmedKey))

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startKeepAlive()
        resetTurnState()
    }

    func beginTurn() {
        ignoreIncomingAudio = false
        replayCache.beginTurn()
        player.resetFirstScheduleFlag()
        resetTurnState()
    }

    /// Sends newly arrived cumulative assistant text to ElevenLabs and flushes
    /// as soon as the chunker emits a complete sentence.
    func append(cumulative text: String) async throws {
        try await reconnectIfClosedBeforeTurnText()
        if !text.hasPrefix(sentText) {
            let common = String(text.commonPrefix(with: sentText, options: .literal))
            if common.isEmpty {
                if !sentText.isEmpty {
                    try await sendJSON(ElevenLabsTTSCodec.flushPayload())
                }
                segmenter.reset()
            }
            sentText = common
        }

        // Only the chunker's Markdown-free segments go on the wire; the raw
        // transcript (asterisks, code fences, URLs) never reaches ElevenLabs.
        let segments = segmenter.consume(cumulative: text)
        sentText = segmenter.committedPrefix
        if !segments.isEmpty {
            onFirstTextSent?()
            lastTextSentAt = ProcessInfo.processInfo.systemUptime
            try await sendJSON(ElevenLabsTTSCodec.textPayload(Self.wireText(segments)))
            try await sendJSON(ElevenLabsTTSCodec.flushPayload())
        }

        if let streamError {
            throw streamError
        }
    }

    /// ElevenLabs wants each text message to end with a space.
    static func wireText(_ segments: [String]) -> String {
        segments.joined(separator: " ") + " "
    }

    /// Sends any text still held back by the boundary rule (a round end,
    /// where trailing text may lack final punctuation), sanitized.
    private func sendRemainder(cumulative text: String) async throws {
        let remaining = segmenter.finish(cumulative: text)
        sentText = segmenter.committedPrefix
        if !remaining.isEmpty {
            onFirstTextSent?()
            lastTextSentAt = ProcessInfo.processInfo.systemUptime
            try await sendJSON(ElevenLabsTTSCodec.textPayload(Self.wireText(remaining)))
        }
        if !remaining.isEmpty || !sentText.isEmpty {
            try await sendJSON(ElevenLabsTTSCodec.flushPayload())
        }
    }

    /// Flushes remaining buffered text without closing the socket (e.g. before a tool round).
    func checkpoint(cumulative text: String) async throws {
        try await append(cumulative: text)
        try await sendRemainder(cumulative: text)
        segmenter.reset()
        sentText = ""
    }

    func finish(cumulative text: String) async throws {
        try await append(cumulative: text)
        try await sendRemainder(cumulative: text)

        isFinished = true
        // Audio for the last text is often still on the wire when nothing is
        // queued yet. Returning then ended the turn before the reply played,
        // so listening resumed under our own voice (build 38 echo). The
        // server's isFinal ends it; quiet after the last audio is the fallback.
        while !Task.isCancelled, !ignoreIncomingAudio, streamError == nil {
            await player.waitUntilFinished()
            if VoiceTTSDrainPolicy.isDrained(
                now: ProcessInfo.processInfo.systemUptime,
                lastTextSentAt: lastTextSentAt,
                lastAudioAt: lastAudioAt,
                playbackPending: VoiceDuplexEngine.shared.hasPendingPlayback,
                serverFinal: didReceiveFinal
            ) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        VoiceAudioDebugStore.append(event: "tts.drained", detail: "audio=\(lastAudioAt != nil) final=\(didReceiveFinal)")
        replayCache.commitTurn()
        if let streamError { throw streamError }
        resetTurnState()
    }

    /// Stops playback and drops in-flight audio without closing the warm socket.
    func cancelPlaybackKeepingConnection() {
        ignoreIncomingAudio = true
        player.stop(teardownEngine: false)
        resetTurnState()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Replays the cached PCM of the last reply. Stops anything already
    /// playing; makes no ElevenLabs request.
    @discardableResult
    func replayLastReply() -> Bool {
        guard let pcm = replayCache.lastReply, !pcm.isEmpty else { return false }
        ignoreIncomingAudio = true
        VoiceDuplexEngine.shared.stopPlayback()
        do {
            try player.start()
        } catch {
            return false
        }
        player.schedule(pcmData: pcm)
        return true
    }

    func cancel(teardownEngine: Bool = true) {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        tearDownSocket()
        player.stop(teardownEngine: teardownEngine)
        connectedVoiceID = ""
        connectedModelID = ""
        ignoreIncomingAudio = false
        resetTurnState()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Private

    private func resetTurnState() {
        sentText = ""
        segmenter.reset()
        isFinished = false
        didReceiveFinal = false
        streamError = nil
        lastTextSentAt = nil
        lastAudioAt = nil
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket, webSocket.state == .running else {
            throw VoiceServiceError.synthesisFailed("ElevenLabs stream is not connected.")
        }
        try await webSocket.send(.string(try VoiceJSON.encode(object)))
        lastSendAt = Date()
    }

    private func receiveLoop() async {
        guard let webSocket else { return }
        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                let code = webSocket.closeCode.rawValue
                let reason = webSocket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                lastCloseDescription = "code=\(code) reason=\(reason) error=\(error.localizedDescription)"
                VoiceAudioDebugStore.append(event: "elevenlabs.ws.closed", detail: lastCloseDescription ?? "")
                print("[ElevenLabsWS] closed \(lastCloseDescription ?? "")")
                if !isFinished && !didReceiveFinal {
                    streamError = error
                }
                finishWaitersResume()
                self.webSocket = nil
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        let incoming = ElevenLabsTTSCodec.parseIncoming(text)
        if let pcm = incoming.audio, !ignoreIncomingAudio {
            lastAudioAt = ProcessInfo.processInfo.systemUptime
            replayCache.append(pcm)
            player.schedule(pcmData: pcm)
        }
        if let errorMessage = incoming.errorMessage {
            streamError = ElevenLabsAPIError.requestFailed(
                ElevenLabsVoiceErrors.userFacingTTSMessage(errorMessage)
            )
        }
        if incoming.isFinal {
            didReceiveFinal = true
            finishWaitersResume()
        }
    }

    private func finishWaitersResume() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            if let streamError {
                waiter.resume(throwing: streamError)
            } else {
                waiter.resume()
            }
        }
    }

    /// ElevenLabs closes an idle socket after ~20 s; slow LLM replies used to
    /// lose the stream. Send the documented " " keepalive before that.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        lastSendAt = Date()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let idle = Date().timeIntervalSince(self.lastSendAt)
                guard ElevenLabsKeepAlivePolicy.shouldSendKeepAlive(
                    secondsSinceLastSend: idle, isConnected: self.isConnected
                ) else {
                    if !self.isConnected { return }
                    continue
                }
                try? await self.sendJSON(ElevenLabsKeepAlivePolicy.payload())
            }
        }
    }

    /// A socket that idled out or was closed by the server is reopened before
    /// the turn sends any text (no audio has been produced yet, so nothing
    /// is duplicated). Mid-turn closes still surface as an error/HTTP fallback.
    private func reconnectIfClosedBeforeTurnText() async throws {
        guard ElevenLabsReconnectPolicy.shouldReconnectBeforeSend(
            isConnected: isConnected,
            turnHasSentText: !sentText.isEmpty,
            hasCredentials: !lastAPIKey.isEmpty && !connectedVoiceID.isEmpty
        ) else { return }
        VoiceAudioDebugStore.append(event: "elevenlabs.ws.reconnect", detail: lastCloseDescription ?? "")
        let voice = connectedVoiceID
        let model = connectedModelID
        try await connect(apiKey: lastAPIKey, voiceID: voice, modelID: model)
    }

    private func tearDownSocket() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }
}
