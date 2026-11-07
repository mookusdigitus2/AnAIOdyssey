// SPDX-License-Identifier: MIT
import Foundation

/// Decides whether a mic buffer may count as the user speaking. Without this
/// the tail of the assistant's own voice (still ringing in the room after the
/// last buffer) triggered barge-in or a bogus utterance.
public enum VoiceMicGate {
    /// Mic energy is ignored for this long after playback drains.
    public static let tailGuardSeconds: Double = 0.6

    public static func shouldAccept(
        isPlayingBack: Bool,
        secondsSincePlaybackEnded: Double?,
        echoCancellationActive: Bool,
        bargeInEnabled: Bool
    ) -> Bool {
        if isPlayingBack {
            return bargeInEnabled && echoCancellationActive
        }
        if let since = secondsSincePlaybackEnded, since < tailGuardSeconds {
            return false
        }
        return true
    }

    /// Whether pausing a reply starts the tail guard. With echo cancellation
    /// the paused reply's tail is cancelled like the reply itself, and the
    /// user is mid-sentence (barge-in): guarding would drop ~0.6 s of their
    /// words. Without it (tap to interrupt) the room tail is still ours.
    public static func pauseStartsTailGuard(echoCancelled: Bool) -> Bool {
        !echoCancelled
    }
}

/// What the recognizer listens for. The session controller is the only one
/// who changes it.
public enum VoiceListenMode: String, Sendable {
    /// Mic buffers are not fed to a recognizer (thinking, HFP playback, idle).
    case off
    /// Hearing a turn; 1.5 s of silence submits it.
    case listening
    /// A reply plays on an echo-cancelled route; any speech pauses it.
    case watchingForBargeIn
}

/// Echo handling by playback state alone (no transcript matching, req. 10
/// and 15). While reply audio plays, only barge-in watching hears the mic,
/// and only when voice processing (or headphones) keeps the reply out of
/// it; listening for a turn never hears a playing reply. The room tail
/// after playback is ignored.
public enum VoiceListenGate {
    public static func feedsRecognizer(
        mode: VoiceListenMode,
        replyPlaying: Bool,
        echoCancelled: Bool,
        roomTailQuiet: Bool
    ) -> Bool {
        guard mode != .off else { return false }
        if replyPlaying { return mode == .watchingForBargeIn && echoCancelled }
        return roomTailQuiet
    }
}

/// ElevenLabs closes an idle stream-input socket after ~20 s. A single space
/// is their documented keepalive; send one before the limit.
public enum ElevenLabsKeepAlivePolicy {
    public static let idleThresholdSeconds: Double = 15

    public static func shouldSendKeepAlive(secondsSinceLastSend: Double, isConnected: Bool) -> Bool {
        isConnected && secondsSinceLastSend >= idleThresholdSeconds
    }

    public static func payload() -> [String: Any] { ["text": " "] }
}

/// Caches the PCM of the reply being spoken so "Replay last reply" is instant
/// and needs no new ElevenLabs call.
public struct VoicePCMReplayCache: Sendable {
    public static let maxBytes = 24_000 * 2 * 180 // ~3 min of 24 kHz mono Int16

    private var pending = Data()
    public private(set) var lastReply: Data?
    public private(set) var sampleRate: Double

    public init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    public var canReplay: Bool { !(lastReply?.isEmpty ?? true) }

    public mutating func beginTurn() { pending.removeAll(keepingCapacity: true) }

    public mutating func append(_ pcm: Data) {
        guard pending.count + pcm.count <= Self.maxBytes else { return }
        pending.append(pcm)
    }

    /// Keeps the turn's audio as the replayable reply; an empty turn keeps the previous one.
    public mutating func commitTurn() {
        if !pending.isEmpty { lastReply = pending }
        pending.removeAll(keepingCapacity: true)
    }
}

/// When to reopen the ElevenLabs socket before sending.
public enum ElevenLabsReconnectPolicy {
    public static func shouldReconnectBeforeSend(
        isConnected: Bool,
        turnHasSentText: Bool,
        hasCredentials: Bool
    ) -> Bool {
        !isConnected && !turnHasSentText && hasCredentials
    }
}
