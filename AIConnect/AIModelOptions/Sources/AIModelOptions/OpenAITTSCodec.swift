// SPDX-License-Identifier: MIT
import Foundation

/// OpenAI `POST /v1/audio/speech`. Text cannot be streamed in; audio can stream
/// back (`stream_format=audio`, `response_format=pcm`) so callers send one
/// request per sentence and pipeline playback.
public enum OpenAITTSCodec {
    public static let defaultModelID = VoiceCatalog.defaultOpenAIModelID
    public static let defaultVoiceID = VoiceCatalog.defaultOpenAIVoiceID
    public static let pcmSampleRate: Double = 24_000
    public static let pcmBytesPerFrame = 2

    public static let models = VoiceCatalog.openAIModels

    /// Voices for `gpt-4o-mini-tts` (and newer). `tts-1` / `tts-1-hd` omit
    /// ballad, verse, marin, and cedar.
    public static let allVoices: [VoiceOption] = [
        VoiceOption(id: "alloy", displayName: "Alloy"),
        VoiceOption(id: "ash", displayName: "Ash"),
        VoiceOption(id: "ballad", displayName: "Ballad"),
        VoiceOption(id: "coral", displayName: "Coral"),
        VoiceOption(id: "echo", displayName: "Echo"),
        VoiceOption(id: "fable", displayName: "Fable"),
        VoiceOption(id: "onyx", displayName: "Onyx"),
        VoiceOption(id: "nova", displayName: "Nova"),
        VoiceOption(id: "sage", displayName: "Sage"),
        VoiceOption(id: "shimmer", displayName: "Shimmer"),
        VoiceOption(id: "verse", displayName: "Verse"),
        VoiceOption(id: "marin", displayName: "Marin"),
        VoiceOption(id: "cedar", displayName: "Cedar"),
    ]

    public static let legacyVoices: [VoiceOption] = allVoices.filter { option in
        !["ballad", "verse", "marin", "cedar"].contains(option.id)
    }

    public static func voices(forModel modelID: String) -> [VoiceOption] {
        switch modelID {
        case "tts-1", "tts-1-hd":
            return legacyVoices
        default:
            return allVoices
        }
    }

    public static func speechURL(baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/audio/speech") else {
            throw VoiceTTSCodecError.invalidURL
        }
        return url
    }

    public static func requestBody(
        model: String,
        voice: String,
        input: String,
        responseFormat: String = "pcm",
        streamFormat: String? = "audio"
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "voice": voice,
            "input": input,
            "response_format": responseFormat,
        ]
        if let streamFormat {
            body["stream_format"] = streamFormat
        }
        return body
    }

    /// Short clip for the picker play/stop button (full MP3, no live streaming).
    public static func previewBody(model: String, voice: String, input: String = VoiceCatalog.previewPhrase) -> [String: Any] {
        requestBody(model: model, voice: voice, input: input, responseFormat: "mp3", streamFormat: nil)
    }

    public static func authorizationHeader(apiKey: String) -> String {
        "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func parseErrorBody(_ data: Data) -> String? {
        guard let object = VoiceJSON.object(from: data) else { return nil }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}

/// Splits arriving PCM bytes onto Int16 frame boundaries so playback can start
/// before the HTTP body finishes.
public enum PCMStreamFramer {
    public static func takeAlignedFrames(
        from buffer: inout Data,
        minBytes: Int,
        bytesPerFrame: Int = OpenAITTSCodec.pcmBytesPerFrame,
        flushAll: Bool = false
    ) -> Data {
        guard bytesPerFrame > 0 else { return Data() }
        let aligned = buffer.count - (buffer.count % bytesPerFrame)
        let threshold = flushAll ? bytesPerFrame : minBytes
        guard aligned >= threshold else { return Data() }
        let chunk = Data(buffer.prefix(aligned))
        buffer.removeFirst(aligned)
        return chunk
    }
}
