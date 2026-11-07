// SPDX-License-Identifier: MIT
import Foundation

/// Why spoken-conversation connections should be opened ahead of the first reply.
public enum VoiceWarmTrigger: String, Sendable, Equatable {
    case launchWithVoiceOn
    case foregroundWithVoiceOn
    case voiceToggledOn
    case microphoneOpened
}

/// Why a warm TTS / LLM connection should be closed.
public enum VoiceIdleReason: String, Sendable, Equatable {
    case voiceToggledOff
    case backgrounded
    case idleTimeout
}

/// First spoken reply vs a later turn in the same warm session.
public enum VoiceTurnKind: String, Sendable, Equatable {
    case first
    case subsequent
}

/// When to pre-warm LLM/TTS sockets and when to tear them down.
///
/// The first spoken reply is the slow one: DNS, TLS, HTTP/2, the ElevenLabs
/// WebSocket, `AVAudioSession`, and the audio engine all pay a cold-start tax.
/// Warm those as soon as voice output is on, keep them across turns, and close
/// on idle / background / voice-off so the next first turn is the only cold one.
public enum VoiceConnectionPolicy {
    /// Close unused sockets after this much silence even if voice is still on.
    public static let idleTimeoutSeconds: TimeInterval = 90
    /// How often a keep-alive flush may be sent on an idle ElevenLabs socket.
    public static let keepAliveIntervalSeconds: TimeInterval = 20

    public static let elevenLabsOrigin = "https://api.elevenlabs.io"
    public static let xaiOrigin = "https://api.x.ai"
    public static let openAIOrigin = "https://api.openai.com"

    public static func shouldWarm(voiceOutputEnabled: Bool, trigger: VoiceWarmTrigger) -> Bool {
        guard voiceOutputEnabled else { return false }
        switch trigger {
        case .launchWithVoiceOn, .foregroundWithVoiceOn, .voiceToggledOn, .microphoneOpened:
            return true
        }
    }

    public static func shouldClose(voiceOutputEnabled: Bool, reason: VoiceIdleReason) -> Bool {
        switch reason {
        case .voiceToggledOff, .backgrounded:
            return true
        case .idleTimeout:
            return true
        }
    }

    /// After an idle close the next spoken reply is a first turn again.
    public static func turnKind(completedSpokenTurns: Int) -> VoiceTurnKind {
        completedSpokenTurns <= 0 ? .first : .subsequent
    }

    public static func resetTurnCount(after reason: VoiceIdleReason) -> Bool {
        shouldClose(voiceOutputEnabled: true, reason: reason)
    }

    /// HTTPS origins to hit so DNS / TLS / HTTP/2 are warm before the first token.
    public static func hostsToPreconnect(
        llmBaseURL: String?,
        ttsProvider: VoiceProvider,
        openAIBaseURL: String? = nil
    ) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []

        func add(_ raw: String?) {
            guard let origin = originURL(from: raw), seen.insert(origin.absoluteString).inserted else { return }
            urls.append(origin)
        }

        add(llmBaseURL)
        switch ttsProvider {
        case .elevenLabs:
            add(elevenLabsOrigin)
        case .openai:
            add(openAIBaseURL ?? openAIOrigin)
        case .xai:
            add(xaiOrigin)
        case .system, .appleIntelligence:
            break
        }
        return urls
    }

    /// Scheme + host only (`https://api.example.com/`) so a HEAD warms the path
    /// without depending on a specific API route existing.
    public static func originURL(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        switch url.scheme?.lowercased() {
        case "wss", "https":
            components.scheme = "https"
        case "ws", "http":
            components.scheme = "http"
        default:
            components.scheme = "https"
        }
        components.host = host
        if let port = url.port {
            components.port = port
        }
        components.path = "/"
        return components.url
    }
}
