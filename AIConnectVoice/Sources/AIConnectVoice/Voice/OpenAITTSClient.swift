// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

/// Per-sentence OpenAI `POST /v1/audio/speech` with streamed PCM playback.
///
/// The Speech API cannot stream text in, so each completed sentence is its own
/// request. `stream_format=audio` + `response_format=pcm` lets playback start
/// before that sentence's body finishes, and pipelining those requests starts
/// audio before the full assistant reply finishes.
@MainActor
final class OpenAITTSClient {
    private let session: URLSession
    let player = PCMStreamPlayer(sampleRate: OpenAITTSCodec.pcmSampleRate)
    private let flushBytes = 2_048
    var onFirstAudio: (() -> Void)?
    var onFirstTextSent: (() -> Void)?

    init(session: URLSession = VoiceNetworkSession.shared) {
        self.session = session
        player.onFirstBufferScheduled = { [weak self] in
            self?.onFirstAudio?()
        }
    }

    func prepare() throws {
        try player.prime()
    }

    func beginTurn() {
        player.resetFirstScheduleFlag()
    }

    func streamSentence(
        text: String,
        apiKey: String,
        baseURL: String,
        model: String,
        voice: String
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VoiceServiceError.notConfigured }

        var request = URLRequest(url: try OpenAITTSCodec.speechURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue(OpenAITTSCodec.authorizationHeader(apiKey: trimmedKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: OpenAITTSCodec.requestBody(
                model: model,
                voice: voice,
                input: trimmed
            )
        )

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
            }
            let detail = OpenAITTSCodec.parseErrorBody(errorBody)
                ?? String(data: errorBody, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw VoiceServiceError.synthesisFailed(detail)
        }

        onFirstTextSent?()
        try player.start()
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            let chunk = PCMStreamFramer.takeAlignedFrames(from: &buffer, minBytes: flushBytes)
            if !chunk.isEmpty {
                player.schedule(pcmData: chunk)
            }
        }
        let remainder = PCMStreamFramer.takeAlignedFrames(from: &buffer, minBytes: 0, flushAll: true)
        if !remainder.isEmpty {
            player.schedule(pcmData: remainder)
        }
    }

    func waitUntilFinished() async {
        await player.waitUntilFinished()
    }

    func stop(teardownEngine: Bool = false) {
        player.stop(teardownEngine: teardownEngine)
    }
}
