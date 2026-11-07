// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import AIModelOptions

enum ElevenLabsAPIError: Error, LocalizedError {
    case notConfigured
    case notFound
    case paidPlanRequired
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "ElevenLabs API key is not configured."
        case .notFound: return ElevenLabsVoiceErrors.notFoundMessage
        case .paidPlanRequired: return ElevenLabsVoiceErrors.paidPlanMessage
        case .requestFailed(let detail): return ElevenLabsVoiceErrors.userFacingTTSMessage(detail)
        case .invalidResponse: return "ElevenLabs returned an unexpected response."
        }
    }
}

/// Minimal HTTP client for ElevenLabs TTS and STT.
struct ElevenLabsAPIClient {
    let apiKey: String
    let session: URLSession

    func synthesizeSpeech(text: String, voiceID: String, modelID: String = "eleven_multilingual_v2") async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsAPIError.notConfigured }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return Data() }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": trimmedText,
            "model_id": modelID,
        ])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func listVoices() async throws -> [VoiceOption] {
        var all: [VoiceOption] = []
        var seen = Set<String>()
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            let page = try await fetchVoicesPage(nextPageToken: token)
            for voice in page.voices where seen.insert(voice.id).inserted {
                all.append(voice)
            }
            token = ElevenLabsTTSCodec.continuePageToken(
                hasMore: page.hasMore,
                nextPageToken: page.nextPageToken,
                previousToken: token
            )
        } while token != nil && pages < ElevenLabsTTSCodec.maxVoicesPages
        return all
    }

    func fetchVoicesPage(nextPageToken: String? = nil) async throws -> ElevenLabsVoicesPage {
        let (data, _) = try await get(url: try ElevenLabsTTSCodec.voicesURL(nextPageToken: nextPageToken))
        return try ElevenLabsTTSCodec.parseVoicesPage(data)
    }

    func getVoice(voiceID: String) async throws -> ElevenLabsVoiceRecord {
        let (data, _) = try await get(url: try ElevenLabsTTSCodec.voiceDetailURL(voiceID: voiceID))
        return try ElevenLabsTTSCodec.parseVoiceDetail(data)
    }

    func findSharedVoice(voiceID: String) async throws -> ElevenLabsVoiceRecord? {
        let (data, _) = try await get(url: try ElevenLabsTTSCodec.sharedVoicesURL(search: voiceID))
        let voices = try ElevenLabsTTSCodec.parseSharedVoices(data)
        return ElevenLabsTTSCodec.matchingSharedVoice(in: voices, voiceID: voiceID)
    }

    func lookupVoice(voiceID: String) async throws -> ElevenLabsVoiceLookup {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        do {
            return .account(try await getVoice(voiceID: trimmed))
        } catch ElevenLabsAPIError.notFound {
            if let shared = try await findSharedVoice(voiceID: trimmed) {
                return .library(shared)
            }
            return .notFound
        }
    }

    func addSharedVoice(publicOwnerID: String, voiceID: String, name: String) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsAPIError.notConfigured }
        var request = URLRequest(url: try ElevenLabsTTSCodec.addSharedVoiceURL(
            publicOwnerID: publicOwnerID,
            voiceID: voiceID
        ))
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ElevenLabsTTSCodec.addSharedVoiceBody(name: name)
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func get(url: URL) async throws -> (Data, URLResponse) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsAPIError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue(trimmedKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return (data, response)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ElevenLabsAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if ElevenLabsVoiceErrors.isNotFound(statusCode: http.statusCode) {
                throw ElevenLabsAPIError.notFound
            }
            if ElevenLabsVoiceErrors.isPaidPlanRestriction(statusCode: http.statusCode, body: body) {
                throw ElevenLabsAPIError.paidPlanRequired
            }
            throw ElevenLabsAPIError.requestFailed("HTTP \(http.statusCode): \(body.prefix(300))")
        }
    }
}
