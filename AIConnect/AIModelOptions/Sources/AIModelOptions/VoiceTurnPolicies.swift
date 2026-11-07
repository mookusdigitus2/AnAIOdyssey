// SPDX-License-Identifier: MIT
import Foundation

/// Barge-in needs at least this many words over a playing reply, so a cough
/// or a single stray word never pauses it (req. 8).
public enum VoiceBargeInPolicy {
    public static let minimumWords = 2

    public static func shouldPause(heard text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count >= minimumWords
    }
}

/// Recognizer failures (req. 12): the first retry is immediate, later ones
/// back off, and a pass that keeps dying stops the session with a message
/// instead of looping. A pass that lived a while before failing (Apple ends
/// long silent passes) resets the count.
public enum VoiceRecoveryPolicy {
    public static let maxConsecutiveFailures = 5
    public static let healthyPassSeconds: TimeInterval = 10
    public static let failureMessage = "Voice input stopped responding. Tap the mic to try again."

    /// Delay before restarting after the `failures`-th consecutive failure.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 1 else { return 0 }
        return min(0.25 * pow(2, Double(failures - 2)), 2)
    }

    public static func shouldGiveUp(afterFailures failures: Int) -> Bool {
        failures >= maxConsecutiveFailures
    }
}

/// When a streamed TTS reply has really finished (req. 7, 15). The socket
/// keeps delivering audio after the last text is sent, so "nothing queued
/// right now" is not the end. The server's `isFinal` is the real signal;
/// without it, wait until audio for the last text has arrived and gone
/// quiet, or give up when the last text produced no audio at all.
public enum VoiceTTSDrainPolicy {
    public static let quietAfterAudio: TimeInterval = 0.8
    /// The last text (e.g. punctuation only) may produce no audio at all.
    public static let firstAudioTimeout: TimeInterval = 3

    public static func isDrained(
        now: TimeInterval,
        lastTextSentAt: TimeInterval?,
        lastAudioAt: TimeInterval?,
        playbackPending: Bool,
        serverFinal: Bool = false
    ) -> Bool {
        if playbackPending { return false }
        if serverFinal { return true }
        guard let sent = lastTextSentAt else { return true }
        if let audio = lastAudioAt, audio >= sent {
            return now - audio >= quietAfterAudio
        }
        return now - sent >= firstAudioTimeout
    }
}

/// The engine owner's runtime echo check (req. 15), run at session start and
/// after every rebuild or route change.
public struct VoiceEchoCheck: Equatable, Sendable {
    /// False only on routes where Apple's voice processing can't run (HFP);
    /// there the mic stays closed during playback instead.
    public var voiceProcessingExpected: Bool
    public var voiceProcessingOn: Bool
    public var playerOnSameEngine: Bool
    public var sessionIsVoiceChat: Bool

    public init(voiceProcessingExpected: Bool, voiceProcessingOn: Bool, playerOnSameEngine: Bool, sessionIsVoiceChat: Bool) {
        self.voiceProcessingExpected = voiceProcessingExpected
        self.voiceProcessingOn = voiceProcessingOn
        self.playerOnSameEngine = playerOnSameEngine
        self.sessionIsVoiceChat = sessionIsVoiceChat
    }

    public var failures: [String] {
        var result: [String] = []
        if voiceProcessingExpected, !voiceProcessingOn { result.append("voiceProcessing=off") }
        if !playerOnSameEngine { result.append("player=detached") }
        if !sessionIsVoiceChat { result.append("mode!=voiceChat") }
        return result
    }

    public var passes: Bool { failures.isEmpty }

    /// Speech may reach the recognizer during playback only when this holds.
    public var echoCancelled: Bool { passes && voiceProcessingOn }

    public var detail: String {
        "vp=\(voiceProcessingOn) expected=\(voiceProcessingExpected) player=\(playerOnSameEngine ? "same-engine" : "detached") voiceChat=\(sessionIsVoiceChat)"
    }
}

/// The inline line in voice mode when speech barge-in is off (no echo
/// cancellation on the route, or the engine's echo check failed): the mic
/// stays closed during playback and the user taps to interrupt (REQ-10, 15).
public enum VoiceInterruptHintPolicy {
    public static let speaker = "Interrupting is off on the speaker. Use headphones to interrupt."
    public static let headset = "Interrupting is off on this headset. Tap to interrupt."
    public static let headphones = "Interrupting is off on these headphones. Tap to interrupt."
    public static let other = "Interrupting by voice is off. Tap to interrupt."

    /// Nil while speech barge-in works.
    public static func text(route: VoiceOutputRouteKind, speechBargeInEnabled: Bool) -> String? {
        guard !speechBargeInEnabled else { return nil }
        switch route {
        case .speaker: return speaker
        case .bluetoothHFP: return headset
        case .headphones: return headphones
        case .unknown: return other
        }
    }
}
