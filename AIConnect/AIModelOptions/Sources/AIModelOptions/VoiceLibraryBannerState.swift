// SPDX-License-Identifier: MIT
import Foundation

/// App-wide banner shown when a voice add finishes, wherever the user is.
public enum VoiceLibraryBannerState: Equatable, Sendable {
    case added(voiceID: String, name: String)
    case failed(voiceID: String, name: String, message: String)
    /// Voice control failed while starting or in the background. Shown
    /// wherever the user is, never as an alert on a screen they already left.
    case voiceSessionFailed(message: String, canRetry: Bool)

    public var message: String {
        switch self {
        case .added(_, let name): return "Added \(name) and set it as your voice"
        case .failed(_, let name, let message): return "Couldn't add \(name): \(message)"
        case .voiceSessionFailed(let message, _): return "Voice stopped: \(message)"
        }
    }

    public var showsRetry: Bool {
        switch self {
        case .added: return false
        case .failed: return true
        case .voiceSessionFailed(_, let canRetry): return canRetry
        }
    }

    /// Shows the warning icon (failures), not the green check.
    public var isProblem: Bool {
        if case .added = self { return false }
        return true
    }

    /// Only a successful add selects the voice.
    public var selectsVoice: Bool {
        if case .added = self { return true }
        return false
    }
}

/// Voice IDs with an add in flight; a second add for the same ID is rejected.
public struct VoiceAddInFlight: Sendable {
    private var ids: Set<String> = []
    public init() {}
    public mutating func begin(_ voiceID: String) -> Bool { ids.insert(voiceID).inserted }
    public mutating func end(_ voiceID: String) { ids.remove(voiceID) }
    public func contains(_ voiceID: String) -> Bool { ids.contains(voiceID) }
}
