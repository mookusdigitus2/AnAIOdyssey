// SPDX-License-Identifier: MIT
import Foundation

/// One ElevenLabs voice from `/v2/voices`, `/v1/voices/{id}`, or `/v1/shared-voices`.
public struct ElevenLabsVoiceRecord: Equatable, Sendable, Codable, Identifiable {
    public var voiceID: String
    public var name: String
    public var previewURL: String?
    public var publicOwnerID: String?
    public var freeUsersAllowed: Bool?

    public var id: String { voiceID }

    public var voiceOption: VoiceOption {
        VoiceOption(id: voiceID, displayName: name, previewURL: previewURL)
    }

    public init(
        voiceID: String,
        name: String,
        previewURL: String? = nil,
        publicOwnerID: String? = nil,
        freeUsersAllowed: Bool? = nil
    ) {
        self.voiceID = voiceID
        self.name = name
        self.previewURL = previewURL
        self.publicOwnerID = publicOwnerID
        self.freeUsersAllowed = freeUsersAllowed
    }
}

/// One page of `GET /v2/voices`.
public struct ElevenLabsVoicesPage: Equatable, Sendable {
    public var voices: [VoiceOption]
    public var hasMore: Bool
    public var nextPageToken: String?

    public init(voices: [VoiceOption], hasMore: Bool, nextPageToken: String?) {
        self.voices = voices
        self.hasMore = hasMore
        self.nextPageToken = nextPageToken
    }
}

/// Result of looking up a pasted voice ID.
public enum ElevenLabsVoiceLookup: Equatable, Sendable {
    case account(ElevenLabsVoiceRecord)
    case library(ElevenLabsVoiceRecord)
    case notFound
}

/// User-facing ElevenLabs voice errors and HTTP/body mapping.
public enum ElevenLabsVoiceErrors {
    public static let paidPlanMessage = "This voice needs a paid ElevenLabs plan."
    public static let notFoundMessage = "No ElevenLabs voice with that ID."
    public static let listFailedMessage = "Couldn't load ElevenLabs voices."
    public static let customVoiceName = "Custom voice"
    public static let keyRejectedMessage = "ElevenLabs API key was rejected."
    public static let unavailableMessage = "ElevenLabs is unavailable."

    public static func isNotFound(statusCode: Int) -> Bool {
        statusCode == 404
    }

    public static func isPaidPlanRestriction(freeUsersAllowed: Bool?) -> Bool {
        freeUsersAllowed == false
    }

    public static func isPaidPlanRestriction(statusCode: Int, body: String) -> Bool {
        if statusCode == 402 { return true }
        return containsPaidPlanSignal(body.lowercased())
    }

    public static func userFacingMessage(statusCode: Int, body: String) -> String {
        if isNotFound(statusCode: statusCode) { return notFoundMessage }
        if isPaidPlanRestriction(statusCode: statusCode, body: body) { return paidPlanMessage }
        if statusCode == 401 { return keyRejectedMessage }
        if statusCode >= 500 { return unavailableMessage }
        return listFailedMessage
    }

    public static func userFacingTTSMessage(_ raw: String) -> String {
        if isPaidPlanRestriction(statusCode: 0, body: raw) { return paidPlanMessage }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? listFailedMessage : trimmed
    }

    private static func containsPaidPlanSignal(_ lower: String) -> Bool {
        let signals = [
            "free user",
            "free_users",
            "free-users",
            "free_users_allowed",
            "paid plan",
            "paid subscription",
            "upgrade your",
            "subscription required",
            "only available to",
            "not available on your current plan",
            "current plan",
            "permission_denied",
            "missing_permissions",
            "insufficient permission",
            "starter plan",
            "this voice is not available",
            "cannot use this voice",
            "can't use this voice",
            "voice library",
            "available_for_tiers",
        ]
        return signals.contains { lower.contains($0) }
    }
}

extension ElevenLabsTTSCodec {
    public static func voicesURL(
        pageSize: Int = defaultVoicesPageSize,
        nextPageToken: String? = nil
    ) throws -> URL {
        var components = URLComponents(string: voicesPath)
        var items = [
            URLQueryItem(name: "page_size", value: String(min(max(pageSize, 1), 100))),
        ]
        let token = nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty {
            items.append(URLQueryItem(name: "next_page_token", value: token))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw VoiceTTSCodecError.invalidURL }
        return url
    }

    public static func voiceDetailURL(voiceID: String) throws -> URL {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(voiceDetailPath)/\(encoded)")
        else {
            throw VoiceTTSCodecError.invalidURL
        }
        return url
    }

    public static func sharedVoicesURL(search: String, pageSize: Int = 30) throws -> URL {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceTTSCodecError.invalidURL }
        var components = URLComponents(string: sharedVoicesPath)
        components?.queryItems = [
            URLQueryItem(name: "search", value: trimmed),
            URLQueryItem(name: "page_size", value: String(min(max(pageSize, 1), 100))),
        ]
        guard let url = components?.url else { throw VoiceTTSCodecError.invalidURL }
        return url
    }

    public static func addSharedVoiceURL(publicOwnerID: String, voiceID: String) throws -> URL {
        let owner = publicOwnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !voice.isEmpty,
              let ownerEnc = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let voiceEnc = voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(addSharedVoicePath)/\(ownerEnc)/\(voiceEnc)")
        else {
            throw VoiceTTSCodecError.invalidURL
        }
        return url
    }

    public static func addSharedVoiceBody(name: String) -> [String: Any] {
        ["new_name": name]
    }

    /// Token for the next `/v2/voices` request, or `nil` to stop.
    public static func continuePageToken(
        hasMore: Bool,
        nextPageToken: String?,
        previousToken: String? = nil
    ) -> String? {
        guard hasMore else { return nil }
        let trimmed = nextPageToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = previousToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != previous else { return nil }
        return trimmed
    }

    /// Parses `GET /v2/voices` (`voices`, `has_more`, `next_page_token`). Also
    /// accepts a v1 `{ "voices": [...] }` body (`has_more` defaults to false).
    public static func parseVoicesPage(_ data: Data) throws -> ElevenLabsVoicesPage {
        guard let object = VoiceJSON.object(from: data) else {
            throw VoiceTTSCodecError.invalidResponse
        }
        let voices = try parseVoiceRows(object["voices"])
        return ElevenLabsVoicesPage(
            voices: voices,
            hasMore: boolValue(object["has_more"]) || boolValue(object["hasMore"]),
            nextPageToken: firstNonEmptyString(object, keys: ["next_page_token", "nextPageToken"])
        )
    }

    /// Parses `GET /v1/voices` or a v2 page into a flat list. Empty lists throw
    /// so a blank body is not treated as a successful catalog.
    public static func parseVoicesResponse(_ data: Data) throws -> [VoiceOption] {
        let page = try parseVoicesPage(data)
        if page.voices.isEmpty { throw VoiceTTSCodecError.invalidResponse }
        return page.voices
    }

    /// Parses `GET /v1/voices/{voice_id}` (a single voice object).
    public static func parseVoiceDetail(_ data: Data) throws -> ElevenLabsVoiceRecord {
        guard let object = VoiceJSON.object(from: data) else {
            throw VoiceTTSCodecError.invalidResponse
        }
        if let record = voiceRecord(from: object) {
            return record
        }
        throw VoiceTTSCodecError.invalidResponse
    }

    /// Parses `GET /v1/shared-voices` (`voices` with `public_owner_id`,
    /// `free_users_allowed`, `preview_url`).
    public static func parseSharedVoices(_ data: Data) throws -> [ElevenLabsVoiceRecord] {
        guard let object = VoiceJSON.object(from: data) else {
            throw VoiceTTSCodecError.invalidResponse
        }
        let rows = object["voices"] as? [[String: Any]] ?? []
        return rows.compactMap(voiceRecord(from:))
    }

    public static func matchingSharedVoice(
        in voices: [ElevenLabsVoiceRecord],
        voiceID: String
    ) -> ElevenLabsVoiceRecord? {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return voices.first { $0.voiceID.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    public static func encodeAddedVoices(_ voices: [ElevenLabsVoiceRecord]) -> String {
        guard let data = try? JSONEncoder().encode(voices),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    public static func decodeAddedVoices(_ raw: String?) -> [ElevenLabsVoiceRecord] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let voices = try? JSONDecoder().decode([ElevenLabsVoiceRecord].self, from: data)
        else {
            return []
        }
        return voices.filter { !$0.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func parseVoiceRows(_ raw: Any?) throws -> [VoiceOption] {
        let rows = raw as? [[String: Any]] ?? []
        return rows.compactMap { row in
            voiceRecord(from: row)?.voiceOption
        }
    }

    private static func voiceRecord(from row: [String: Any]) -> ElevenLabsVoiceRecord? {
        let id = firstNonEmptyString(row, keys: ["voice_id", "voiceId", "id"]) ?? ""
        guard !id.isEmpty else { return nil }
        let name = firstNonEmptyString(row, keys: ["name"]) ?? ""
        return ElevenLabsVoiceRecord(
            voiceID: id,
            name: name.isEmpty ? ElevenLabsVoiceErrors.customVoiceName : name,
            previewURL: firstNonEmptyString(row, keys: ["preview_url", "previewUrl"]),
            publicOwnerID: firstNonEmptyString(row, keys: ["public_owner_id", "publicOwnerId"]),
            freeUsersAllowed: optionalBool(row, keys: ["free_users_allowed", "freeUsersAllowed"])
        )
    }

    private static func firstNonEmptyString(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        optionalBoolValue(value) ?? false
    }

    private static func optionalBool(_ row: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let parsed = optionalBoolValue(row[key]) { return parsed }
        }
        return nil
    }

    private static func optionalBoolValue(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        if let text = value as? String {
            let lower = text.lowercased()
            if ["true", "1", "yes"].contains(lower) { return true }
            if ["false", "0", "no"].contains(lower) { return false }
        }
        return nil
    }
}
