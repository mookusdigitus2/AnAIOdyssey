// SPDX-License-Identifier: MIT
import Foundation

/// Which chat run may speak or touch speech state (B2, B3). ChatsView keeps
/// one and routes every speech side effect of a run through it: only the
/// newest turn is current, and a voice turn owns speech only while the voice
/// session it was submitted in is still live (Stop, Back, background and
/// interruptions end it).
@MainActor
public final class VoiceReplySpeechOwner {
    public struct Turn: Equatable, Sendable {
        public let token: Int
        /// The voice session token at submit; nil for a turn outside voice mode.
        public let voiceSession: Int?
    }

    public private(set) var currentToken = 0

    public init() {}

    /// The next turn's identity. It becomes current only when `adopt`ed
    /// (the submit point accepted and recorded it).
    public func nextTurn(voiceSession: Int?) -> Turn {
        Turn(token: currentToken + 1, voiceSession: voiceSession)
    }

    @discardableResult
    public func adopt(_ turn: Turn) -> Turn {
        currentToken = turn.token
        return turn
    }

    public func isCurrent(_ turn: Turn) -> Bool { turn.token == currentToken }

    public func owns(_ turn: Turn, isSessionLive: (Int) -> Bool) -> Bool {
        isCurrent(turn) && (turn.voiceSession.map(isSessionLive) ?? true)
    }

    /// Starts speech for a turn. Ownership is checked again after `prepare`
    /// (it awaits the audio session): a Stop or Back during that await means
    /// nothing is armed and the audio it prepared is released. A newer turn
    /// taking over during the await is left alone: the audio is now its.
    public func beginSpeech(
        for turn: Turn,
        isSessionLive: (Int) -> Bool,
        prepare: () async -> Void,
        arm: () -> Void,
        release: () -> Void
    ) async -> Bool {
        guard owns(turn, isSessionLive: isSessionLive) else { return false }
        await prepare()
        guard owns(turn, isSessionLive: isSessionLive) else {
            if isCurrent(turn) { release() }
            return false
        }
        arm()
        return true
    }

    /// A run's cleanup (cancel, defer): only while it is still the current turn.
    public func cleanUp(_ turn: Turn, _ body: () -> Void) {
        if isCurrent(turn) { body() }
    }
}
