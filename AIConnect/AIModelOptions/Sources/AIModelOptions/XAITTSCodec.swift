// SPDX-License-Identifier: MIT
import Foundation

/// xAI bidirectional TTS WebSocket (`wss://api.x.ai/v1/tts`).
///
/// Config is query params — a bare `/v1/tts` URL returns 400. Auth is
/// `Authorization: Bearer`. Send `text.delta` per sentence, then `text.done`.
/// Receive `audio.delta` (base64 in `delta`) until `audio.done`; handle `error`.
public enum XAITTSCodec {
    public static let webSocketPath = "wss://api.x.ai/v1/tts"
    public static let voicesPath = "https://api.x.ai/v1/tts/voices"
    public static let defaultVoice = VoiceCatalog.defaultXAIVoiceID
    public static let defaultLanguage = "en"
    public static let defaultCodec = "pcm"
    public static let defaultSampleRate = 24_000
    public static let sampleRate: Double = 24_000

    public struct ConnectionConfig: Equatable, Sendable {
        public var language: String
        public var voice: String
        public var codec: String
        public var sampleRate: Int
        public var optimizeStreamingLatency: Int

        public init(
            language: String = XAITTSCodec.defaultLanguage,
            voice: String = XAITTSCodec.defaultVoice,
            codec: String = XAITTSCodec.defaultCodec,
            sampleRate: Int = XAITTSCodec.defaultSampleRate,
            optimizeStreamingLatency: Int = 1
        ) {
            self.language = language
            self.voice = voice
            self.codec = codec
            self.sampleRate = sampleRate
            self.optimizeStreamingLatency = optimizeStreamingLatency
        }
    }

    /// Builds `wss://api.x.ai/v1/tts?...`. Language is required; omitting query
    /// params is rejected by the server with HTTP 400.
    public static func webSocketURL(_ config: ConnectionConfig = ConnectionConfig()) throws -> URL {
        let language = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty, !voice.isEmpty else { throw VoiceTTSCodecError.invalidURL }
        guard var components = URLComponents(string: webSocketPath) else {
            throw VoiceTTSCodecError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "voice", value: voice),
            URLQueryItem(name: "codec", value: config.codec),
            URLQueryItem(name: "sample_rate", value: String(config.sampleRate)),
            URLQueryItem(
                name: "optimize_streaming_latency",
                value: String(config.optimizeStreamingLatency)
            ),
        ]
        guard let url = components.url, url.query != nil, !(url.query?.isEmpty ?? true) else {
            throw VoiceTTSCodecError.invalidURL
        }
        return url
    }

    public static func authorizationHeader(apiKey: String) -> String {
        "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func voicesURL() throws -> URL {
        guard let url = URL(string: voicesPath) else { throw VoiceTTSCodecError.invalidURL }
        return url
    }

    public static func textDeltaMessage(_ delta: String) -> [String: Any] {
        ["type": "text.delta", "delta": delta]
    }

    public static func textDoneMessage() -> [String: Any] {
        ["type": "text.done"]
    }

    public static func textClearMessage() -> [String: Any] {
        ["type": "text.clear"]
    }

    public enum Incoming: Equatable, Sendable {
        case audioDelta(Data)
        case audioDone
        case audioClear
        case error(String)
        case ignored
    }

    public static func parseIncoming(_ text: String) -> Incoming {
        guard let object = VoiceJSON.object(from: text),
              let type = object["type"] as? String else {
            return .ignored
        }
        switch type {
        case "audio.delta":
            guard let delta = object["delta"] as? String, !delta.isEmpty,
                  let data = Data(base64Encoded: delta) else {
                return .ignored
            }
            return .audioDelta(data)
        case "audio.done":
            return .audioDone
        case "audio.clear":
            return .audioClear
        case "error":
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(message?.isEmpty == false ? message! : "xAI TTS error")
        default:
            return .ignored
        }
    }

    public static func unaryURL() throws -> URL {
        guard let url = URL(string: "https://api.x.ai/v1/tts") else { throw VoiceTTSCodecError.invalidURL }
        return url
    }

    public static func unaryBody(text: String, voiceID: String, language: String = defaultLanguage) -> [String: Any] {
        [
            "text": text,
            "voice_id": voiceID,
            "language": language,
        ]
    }

    /// Parses `GET /v1/tts/voices` (`{ "voices": [{ "voice_id", "name", preview URL }] }`).
    public static func parseVoicesResponse(_ data: Data) throws -> [VoiceOption] {
        try VoiceCatalog.parseNamedVoices(
            data,
            idKeys: ["voice_id", "id"],
            nameKeys: ["name"],
            previewKeys: ["preview_url", "previewUrl", "sample_url", "sampleUrl"]
        )
    }
}
