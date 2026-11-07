// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation
import AIModelOptions

/// Plays a short voice sample for the picker play/stop button.
///
/// Uses the provider preview URL when one exists; otherwise synthesizes
/// `VoiceCatalog.previewPhrase`. Clips are stored in `VoicePreviewSampleCache`
/// so SwiftUI redraws never hit the network again.
@MainActor
public final class VoicePreviewService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = VoicePreviewService()

    @Published public private(set) var playingCacheKey: String?
    @Published public private(set) var loadingCacheKey: String?
    @Published public private(set) var lastError: String?

    private let session: URLSession
    private let cache: VoicePreviewSampleCache
    private var player: AVAudioPlayer?
    private var systemSynthesizer: AVSpeechSynthesizer?
    /// Bumped by stop(); an in-flight fetch/session prep that finishes after
    /// Back or Cancel sees a stale generation and does not start playing.
    private var generation = 0
    private var fetchTask: Task<Data, Error>?

    public init(session: URLSession = .shared, cache: VoicePreviewSampleCache = .shared) {
        self.session = session
        self.cache = cache
        super.init()
    }

    public func isPlaying(cacheKey: String) -> Bool { playingCacheKey == cacheKey }
    public func isLoading(cacheKey: String) -> Bool { loadingCacheKey == cacheKey }

    public func toggle(
        provider: VoiceProvider,
        voice: VoiceOption,
        apiKey: String,
        baseURL: String? = nil
    ) async {
        let key = VoiceCatalog.previewCacheKey(provider: provider, voiceID: voice.id)
        if playingCacheKey == key {
            stop()
            return
        }
        await play(provider: provider, voice: voice, apiKey: apiKey, baseURL: baseURL)
    }

    public func stop() {
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        systemSynthesizer?.stopSpeaking(at: .immediate)
        playingCacheKey = nil
        loadingCacheKey = nil
    }

    private func play(
        provider: VoiceProvider,
        voice: VoiceOption,
        apiKey: String,
        baseURL: String?
    ) async {
        let key = VoiceCatalog.previewCacheKey(provider: provider, voiceID: voice.id)
        stop()

        if provider == .system {
            playSystem(voiceID: voice.id, cacheKey: key)
            return
        }

        let token = generation
        if let cached = cache.data(for: key) {
            await playData(cached, cacheKey: key, token: token)
            return
        }

        loadingCacheKey = key
        lastError = nil
        do {
            let task = Task {
                try await self.fetchSample(provider: provider, voice: voice, apiKey: apiKey, baseURL: baseURL)
            }
            fetchTask = task
            let data = try await task.value
            cache.store(data, for: key)
            guard token == generation, loadingCacheKey == key else { return }
            loadingCacheKey = nil
            await playData(data, cacheKey: key, token: token)
        } catch {
            guard token == generation else { return }
            if loadingCacheKey == key {
                loadingCacheKey = nil
            }
            lastError = ElevenLabsVoiceErrors.userFacingTTSMessage(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func fetchSample(
        provider: VoiceProvider,
        voice: VoiceOption,
        apiKey: String,
        baseURL: String?
    ) async throws -> Data {
        if let preview = voice.previewURL, let url = URL(string: preview) {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                return data
            }
        }
        switch provider {
        case .elevenLabs:
            return try await ElevenLabsAPIClient(apiKey: apiKey, session: session).synthesizeSpeech(
                text: VoiceCatalog.previewPhrase,
                voiceID: voice.id,
                modelID: VoiceCatalog.defaultElevenLabsModelID
            )
        case .openai:
            return try await synthesizeOpenAI(apiKey: apiKey, baseURL: baseURL, voiceID: voice.id)
        case .xai:
            return try await synthesizeXAI(apiKey: apiKey, voiceID: voice.id)
        case .system, .appleIntelligence:
            return Data()
        }
    }

    private func synthesizeOpenAI(apiKey: String, baseURL: String?, voiceID: String) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VoiceServiceError.notConfigured }
        var request = URLRequest(url: try OpenAITTSCodec.speechURL(baseURL: baseURL ?? RemoteConnection.defaultOpenAIBaseURL))
        request.httpMethod = "POST"
        request.setValue(OpenAITTSCodec.authorizationHeader(apiKey: trimmedKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: OpenAITTSCodec.previewBody(
                model: VoiceCatalog.defaultOpenAIModelID,
                voice: voiceID
            )
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = OpenAITTSCodec.parseErrorBody(data) ?? "HTTP \(http.statusCode)"
            throw VoiceServiceError.synthesisFailed(detail)
        }
        return data
    }

    private func synthesizeXAI(apiKey: String, voiceID: String) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw VoiceServiceError.notConfigured }
        var request = URLRequest(url: try XAITTSCodec.unaryURL())
        request.httpMethod = "POST"
        request.setValue(XAITTSCodec.authorizationHeader(apiKey: trimmedKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: XAITTSCodec.unaryBody(text: VoiceCatalog.previewPhrase, voiceID: voiceID)
        )
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceServiceError.synthesisFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    private func playData(_ data: Data, cacheKey: String, token: Int) async {
        guard !data.isEmpty else { return }
        do {
            #if os(iOS)
            // Was a synchronous setCategory/setActive on the main thread.
            try await VoiceAudioSession.prepareForPlaybackAsync()
            #endif
            guard token == generation else { return }
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = 1.0
            self.player = player
            playingCacheKey = cacheKey
            guard player.play() else {
                self.player = nil
                playingCacheKey = nil
                return
            }
        } catch {
            playingCacheKey = nil
        }
    }

    private func playSystem(voiceID: String, cacheKey: String) {
        #if os(macOS) || os(iOS)
        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: VoiceCatalog.previewPhrase)
        if !voiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        playingCacheKey = cacheKey
        synthesizer.speak(utterance)
        #endif
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.player = nil
            self.playingCacheKey = nil
        }
    }
}

/// On-device System TTS voices with friendly names only.
public enum SystemVoiceCatalog {
    public static func voices() -> [VoiceOption] {
        #if os(macOS) || os(iOS)
        let preferredPrefix = (Locale.preferredLanguages.first ?? "en")
            .split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        let matches = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(preferredPrefix) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let source = matches.isEmpty ? AVSpeechSynthesisVoice.speechVoices() : matches
        var seenNames: [String: Int] = [:]
        return source.map { voice in
            let count = seenNames[voice.name, default: 0]
            seenNames[voice.name] = count + 1
            let display: String
            if count == 0 {
                display = voice.name
            } else {
                display = "\(voice.name) (\(voice.language))"
            }
            return VoiceOption(id: voice.identifier, displayName: display)
        }
        #else
        return VoiceCatalog.voices(for: .system)
        #endif
    }
}
