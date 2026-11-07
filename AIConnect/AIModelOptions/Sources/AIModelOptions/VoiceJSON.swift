// SPDX-License-Identifier: MIT
import Foundation

/// Shared JSON helpers for TTS WebSocket and HTTP codecs.
public enum VoiceJSON {
    public static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoiceTTSCodecError.encodingFailed
        }
        return string
    }

    public static func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum VoiceTTSCodecError: Error, Equatable {
    case encodingFailed
    case invalidURL
    case invalidResponse
}
