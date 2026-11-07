// SPDX-License-Identifier: MIT
import Foundation

/// ElevenLabs WebSocket `/stream-input` encoding (text in, PCM audio out).
public enum ElevenLabsTTSCodec {
    public static let defaultModelID = VoiceCatalog.defaultElevenLabsModelID
    public static let pcmOutputFormat = "pcm_24000"
    public static let sampleRate: Double = 24_000
    public static let voicesPath = "https://api.elevenlabs.io/v2/voices"
    public static let voiceDetailPath = "https://api.elevenlabs.io/v1/voices"
    public static let sharedVoicesPath = "https://api.elevenlabs.io/v1/shared-voices"
    public static let addSharedVoicePath = "https://api.elevenlabs.io/v1/voices/add"
    public static let defaultVoicesPageSize = 100
    public static let maxVoicesPages = 20

    public static func streamInputURL(
        voiceID: String,
        modelID: String = defaultModelID,
        outputFormat: String = pcmOutputFormat
    ) throws -> URL {
        let trimmedVoice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoice.isEmpty else { throw VoiceTTSCodecError.invalidURL }
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-speech/\(trimmedVoice)/stream-input")
        components?.queryItems = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "output_format", value: outputFormat),
        ]
        guard let url = components?.url else { throw VoiceTTSCodecError.invalidURL }
        return url
    }

    /// Valid range per ElevenLabs stream-input: each entry must be 50...500.
    public static let chunkLengthRange: ClosedRange<Int> = 50...500
    public static let chunkLengthSchedule: [Int] = [50, 90, 120, 160]

    public static func bootstrapPayload(apiKey: String) -> [String: Any] {
        [
            "text": " ",
            "xi_api_key": apiKey,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.8,
            ],
            "generation_config": [
                // Smaller first flush so the opening clause starts audio sooner.
                // ElevenLabs rejects values outside 50...500 ("chunk length cannot
                // be smaller than 50"), which killed the socket and froze voice mode.
                "chunk_length_schedule": chunkLengthSchedule,
            ],
        ]
    }

    public static func textPayload(_ text: String, flush: Bool = false) -> [String: Any] {
        if flush {
            return ["text": text, "flush": true]
        }
        return ["text": text]
    }

    public static func flushPayload() -> [String: Any] {
        ["text": " ", "flush": true]
    }

    public static func closePayload() -> [String: Any] {
        ["text": ""]
    }

    public struct Incoming: Equatable, Sendable {
        public var audio: Data?
        public var isFinal: Bool
        public var errorMessage: String?

        public init(audio: Data? = nil, isFinal: Bool = false, errorMessage: String? = nil) {
            self.audio = audio
            self.isFinal = isFinal
            self.errorMessage = errorMessage
        }

        public var isIgnored: Bool {
            audio == nil && !isFinal && errorMessage == nil
        }
    }

    public static func parseIncoming(_ text: String) -> Incoming {
        guard let object = VoiceJSON.object(from: text) else { return Incoming() }

        var incoming = Incoming()
        if let audioBase64 = object["audio"] as? String, !audioBase64.isEmpty,
           let pcm = Data(base64Encoded: audioBase64) {
            incoming.audio = pcm
        }
        if let isFinal = object["isFinal"] as? Bool, isFinal {
            incoming.isFinal = true
        }
        if let errorMessage = object["message"] as? String,
           incoming.audio == nil,
           object["isFinal"] == nil {
            incoming.errorMessage = errorMessage
        }
        return incoming
    }

    /// Length of the longest prefix that ends at a safe TTS boundary: a
    /// punctuation mark (optionally trailed by closing quotes/brackets)
    /// followed by whitespace, or a line feed / CRLF. Requiring whitespace
    /// after punctuation avoids splitting decimals ("3.14") and URLs.
    public static func safeBlockLength(of text: String) -> Int {
        let punctuation: Set<Character> = [".", "!", "?", ",", ";", ":", "…"]
        let closing: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}"]
        var lastBoundary = 0
        var count = 0
        var pendingPunctuation = false
        for character in text {
            count += 1
            if character.isNewline {
                lastBoundary = count
                pendingPunctuation = false
            } else if character.isWhitespace {
                if pendingPunctuation { lastBoundary = count }
                pendingPunctuation = false
            } else if punctuation.contains(character) {
                pendingPunctuation = true
            } else if closing.contains(character) {
                // Closers between punctuation and whitespace keep the boundary
                // alive (e.g. «He said "stop." » cuts after the quote).
            } else {
                pendingPunctuation = false
            }
        }
        return lastBoundary
    }

}
