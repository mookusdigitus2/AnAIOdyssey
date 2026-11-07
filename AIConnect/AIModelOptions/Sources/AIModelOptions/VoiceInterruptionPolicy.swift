// SPDX-License-Identifier: MIT
import Foundation

/// What voice control does with an audio-session interruption (incoming
/// call, Siri, alarm).
public enum VoiceInterruptionCommand: String, Sendable, Equatable {
    /// Send the controller a Stop: one clean teardown, the text reply keeps streaming.
    case stopSession
    /// Do nothing. The mic only comes back when the user taps it.
    case ignore
}

public enum VoiceInterruptionPolicy {
    /// Inline line above the composer after an interruption stopped voice.
    public static let pausedNotice = "Voice paused for a call. Tap the mic to continue."

    /// `began` stops an active session. `ended` never restarts the mic,
    /// even with `.shouldResume`.
    public static func command(began: Bool, shouldResume: Bool, sessionActive: Bool) -> VoiceInterruptionCommand {
        guard began else { return .ignore }
        return sessionActive ? .stopSession : .ignore
    }
}
