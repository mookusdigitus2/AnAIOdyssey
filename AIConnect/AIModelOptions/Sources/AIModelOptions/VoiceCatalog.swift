// SPDX-License-Identifier: MIT
import Foundation

/// Spoken-reply (TTS) backend selected in Settings.
public enum VoiceProvider: String, CaseIterable, Identifiable, Sendable {
    case system
    case elevenLabs = "elevenlabs"
    case openai
    case xai
    case appleIntelligence = "apple_intelligence"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .elevenLabs: return "ElevenLabs"
        case .openai: return "OpenAI"
        case .xai: return "xAI"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }
}

public struct VoiceOption: Identifiable, Equatable, Sendable {
    public let id: String
    /// Friendly name only ("Ara", "Alloy") — never a provider or model id.
    public let displayName: String
    /// Provider sample clip when the voices API supplies one.
    public let previewURL: String?

    public init(id: String, displayName: String, previewURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.previewURL = previewURL
    }
}

public struct VoiceModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Models and voices offered per TTS provider. The Settings picker only lists
/// providers that already have a configured key (System is always available).
public enum VoiceCatalog {
    public static let defaultElevenLabsModelID = "eleven_flash_v2_5"
    public static let defaultElevenLabsVoiceID = "21m00Tcm4TlvDq8ikWAM"
    public static let defaultOpenAIModelID = "gpt-4o-mini-tts"
    public static let defaultOpenAIVoiceID = "alloy"
    public static let defaultXAIVoiceID = "eve"
    /// Fixed line used when a provider has no preview URL. Cached per voice.
    public static let previewPhrase = "Hello, this is a preview of this voice."

    public static func previewCacheKey(provider: VoiceProvider, voiceID: String) -> String {
        "\(provider.rawValue)|\(voiceID)"
    }

    public static let elevenLabsModels: [VoiceModelOption] = [
        VoiceModelOption(id: "eleven_flash_v2_5", displayName: "Flash v2.5"),
        VoiceModelOption(id: "eleven_turbo_v2_5", displayName: "Turbo v2.5"),
        VoiceModelOption(id: "eleven_multilingual_v2", displayName: "Multilingual v2"),
    ]

    public static let elevenLabsVoices: [VoiceOption] = [
        VoiceOption(id: "21m00Tcm4TlvDq8ikWAM", displayName: "Rachel"),
        VoiceOption(id: "EXAVITQu4vr4xnSDxMaL", displayName: "Sarah"),
        VoiceOption(id: "JBFqnCBsd6RMkjVDRZzb", displayName: "George"),
        VoiceOption(id: "nPczCjzI2devNBz1zQrb", displayName: "Brian"),
        VoiceOption(id: "FGY2WhTYpPnrIDTdsKH5", displayName: "Laura"),
        VoiceOption(id: "TX3LPaxmHKxFdv7VOQHJ", displayName: "Liam"),
        VoiceOption(id: "Xb7hH8MSUJpSbSDYk0k2", displayName: "Alice"),
        VoiceOption(id: "pFZP5JQG7iQjIQuC4Bku", displayName: "Lily"),
        VoiceOption(id: "onwK4e9ZLuTAKqWW03F9", displayName: "Daniel"),
        VoiceOption(id: "pqHfZKP75CvOlQylNhV4", displayName: "Bill"),
    ]

    public static let openAIModels: [VoiceModelOption] = [
        VoiceModelOption(id: "gpt-4o-mini-tts", displayName: "gpt-4o-mini-tts"),
        VoiceModelOption(id: "tts-1", displayName: "tts-1"),
        VoiceModelOption(id: "tts-1-hd", displayName: "tts-1-hd"),
    ]

    public static let xaiVoices: [VoiceOption] = [
        VoiceOption(id: "eve", displayName: "Eve"),
        VoiceOption(id: "ara", displayName: "Ara"),
    ]

    /// System is always listed. Other providers appear only when their key is set.
    public static func availableProviders(
        elevenLabsKeyConfigured: Bool,
        openAIKeyConfigured: Bool,
        xaiKeyConfigured: Bool
    ) -> [VoiceProvider] {
        var providers: [VoiceProvider] = [.system]
        if elevenLabsKeyConfigured { providers.append(.elevenLabs) }
        if openAIKeyConfigured { providers.append(.openai) }
        if xaiKeyConfigured { providers.append(.xai) }
        return providers
    }

    public static func models(for provider: VoiceProvider) -> [VoiceModelOption] {
        switch provider {
        case .elevenLabs: return elevenLabsModels
        case .openai: return openAIModels
        case .system, .xai, .appleIntelligence: return []
        }
    }

    public static func voices(for provider: VoiceProvider, modelID: String? = nil) -> [VoiceOption] {
        switch provider {
        case .elevenLabs: return elevenLabsVoices
        case .openai: return OpenAITTSCodec.voices(forModel: modelID ?? defaultOpenAIModelID)
        case .xai: return xaiVoices
        case .system: return [VoiceOption(id: "", displayName: "Default")]
        case .appleIntelligence: return []
        }
    }

    /// Falls back to System when the stored provider is missing or no longer keyed.
    public static func resolvedProvider(
        _ stored: String,
        available: [VoiceProvider]
    ) -> VoiceProvider {
        let parsed = VoiceProvider(rawValue: stored) ?? .system
        return available.contains(parsed) ? parsed : .system
    }

    public static func resolvedModelID(_ stored: String, for provider: VoiceProvider) -> String {
        let options = models(for: provider)
        guard !options.isEmpty else { return stored }
        if options.contains(where: { $0.id == stored }) { return stored }
        return options[0].id
    }

    public static func resolvedVoiceID(
        _ stored: String,
        for provider: VoiceProvider,
        modelID: String? = nil
    ) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = voices(for: provider, modelID: modelID)
        if options.contains(where: { $0.id == trimmed }) { return trimmed }
        if !trimmed.isEmpty { return trimmed }
        switch provider {
        case .elevenLabs: return defaultElevenLabsVoiceID
        case .openai: return defaultOpenAIVoiceID
        case .xai: return defaultXAIVoiceID
        case .system, .appleIntelligence: return ""
        }
    }

    /// Picker rows include a stored custom ID that is not in the bundled catalog.
    public static func voicesIncludingCurrent(
        _ currentID: String,
        for provider: VoiceProvider,
        modelID: String? = nil
    ) -> [VoiceOption] {
        var options = voices(for: provider, modelID: modelID)
        let trimmed = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !options.contains(where: { $0.id == trimmed }) else {
            return options
        }
        options.insert(VoiceOption(id: trimmed, displayName: trimmed), at: 0)
        return options
    }

    /// ElevenLabs picker: persisted "Added Voices" first, then the fetched /
    /// bundled catalog. The saved `elevenLabsVoiceID` is always kept, even when
    /// the account list omitted it.
    public static func elevenLabsPickerSections(
        fetched: [VoiceOption],
        added: [VoiceOption],
        currentID: String
    ) -> (added: [VoiceOption], catalog: [VoiceOption]) {
        let catalogBase = mergeVoiceLists(fetched, fallingBackTo: elevenLabsVoices)
        var seenAdded = Set<String>()
        var addedOut: [VoiceOption] = []

        func appendAdded(_ option: VoiceOption) {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenAdded.contains(id) else { return }
            seenAdded.insert(id)
            addedOut.append(VoiceOption(id: id, displayName: option.displayName, previewURL: option.previewURL))
        }

        for option in added {
            appendAdded(option)
        }

        let trimmed = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !seenAdded.contains(trimmed),
           !catalogBase.contains(where: { $0.id == trimmed }) {
            appendAdded(VoiceOption(id: trimmed, displayName: ElevenLabsVoiceErrors.customVoiceName))
        }

        let catalog = catalogBase.filter { !seenAdded.contains($0.id) }
        return (addedOut, catalog)
    }

    /// Never falls back to `voices.first` — a missing saved ID stays selected
    /// as a custom row instead of silently switching the picker.
    public static func selectedVoice(currentID: String, from voices: [VoiceOption]) -> VoiceOption? {
        let trimmed = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = voices.first(where: { $0.id == trimmed }) {
            return match
        }
        if !trimmed.isEmpty {
            return VoiceOption(id: trimmed, displayName: ElevenLabsVoiceErrors.customVoiceName)
        }
        return voices.first
    }

    public static func mergeVoiceLists(_ primary: [VoiceOption], fallingBackTo bundled: [VoiceOption]) -> [VoiceOption] {
        var seen = Set(primary.map(\.id))
        var merged = primary
        for option in bundled where !seen.contains(option.id) {
            seen.insert(option.id)
            merged.append(option)
        }
        return merged
    }

    public static func parseNamedVoices(
        _ data: Data,
        idKeys: [String],
        nameKeys: [String],
        previewKeys: [String]
    ) throws -> [VoiceOption] {
        guard let object = VoiceJSON.object(from: data) else {
            throw VoiceTTSCodecError.invalidResponse
        }
        let rawVoices = object["voices"] as? [[String: Any]] ?? []
        let parsed: [VoiceOption] = rawVoices.compactMap { row in
            let id = firstString(row, keys: idKeys)
            guard !id.isEmpty else { return nil }
            let name = firstString(row, keys: nameKeys)
            let preview = firstString(row, keys: previewKeys)
            return VoiceOption(
                id: id,
                displayName: name.isEmpty ? friendlyName(fromID: id) : name,
                previewURL: preview.isEmpty ? nil : preview
            )
        }
        if parsed.isEmpty { throw VoiceTTSCodecError.invalidResponse }
        return parsed
    }

    /// Turns `eve` / `alloy` into `Eve` / `Alloy` when the API omits a name.
    public static func friendlyName(fromID id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    private static func firstString(_ row: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = row[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }
}

/// In-memory sample cache so picker redraws never re-fetch a clip.
public final class VoicePreviewSampleCache: @unchecked Sendable {
    public static let shared = VoicePreviewSampleCache()

    private let lock = NSLock()
    private var samples: [String: Data] = [:]

    public init() {}

    public func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return samples[key]
    }

    public func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        lock.lock()
        samples[key] = data
        lock.unlock()
    }
}
