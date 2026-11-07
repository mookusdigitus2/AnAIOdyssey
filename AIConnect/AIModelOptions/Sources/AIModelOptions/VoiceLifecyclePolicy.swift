// SPDX-License-Identifier: MIT
import Foundation

/// Why voice might be paused or torn down. View rebuilds and size-class
/// changes must not stop TTS or listening.
public enum VoiceLifecycleReason: String, Sendable, Equatable {
    case viewDisappear
    case sizeClassChange
    case sceneInactive
    case sceneBackground
    case sceneForeground
    case interruptionEndedShouldResume
    case userExitedVoice
    case userLeftChat
    case sceneDiscarded
}

/// Lifetime rules for the shared voice service. The service lives on the app
/// model, above PhoneRoot / tablet Root, so a layout swap cannot kill audio.
public enum VoiceLeaveChatStep: String, Sendable, Equatable {
    case navigate
    case teardownVoice
}

public enum VoiceLifecyclePolicy {
    /// Back from a chat: pop the view first, then stop voice on a later
    /// main-actor turn so audio teardown never sits inside the Back tap.
    public static let leaveChatOrder: [VoiceLeaveChatStep] = [.navigate, .teardownVoice]

    /// Wait this long after a route change before starting the engine so HFP
    /// can finish opening (the car chime) and report a real hardware format.
    public static let routeSettleMilliseconds = 250

    /// A chat reply keeps generating after Back (run center), but it stops
    /// feeding TTS once its chat is off screen so audio never restarts.
    public static func shouldKeepSpeakingReply(speechEnabled: Bool, chatOnScreen: Bool) -> Bool {
        speechEnabled && chatOnScreen
    }

    public static func shouldTeardownConversation(reason: VoiceLifecycleReason) -> Bool {
        switch reason {
        case .userExitedVoice, .userLeftChat, .sceneDiscarded:
            return true
        case .viewDisappear, .sizeClassChange, .sceneInactive, .sceneBackground,
             .sceneForeground, .interruptionEndedShouldResume:
            return false
        }
    }

    public static func shouldCancelSpeech(reason: VoiceLifecycleReason) -> Bool {
        shouldTeardownConversation(reason: reason)
    }

    /// Listening cannot continue reliably in the background; pause, then resume.
    public static func shouldPauseListening(reason: VoiceLifecycleReason) -> Bool {
        switch reason {
        case .sceneBackground, .sceneInactive:
            return true
        default:
            return false
        }
    }

    public static func shouldResumeListening(reason: VoiceLifecycleReason, voiceControlArmed: Bool) -> Bool {
        guard voiceControlArmed else { return false }
        switch reason {
        case .sceneForeground, .interruptionEndedShouldResume:
            return true
        default:
            return false
        }
    }

    public static func shouldKeepSpeakingInBackground(audioBackgroundModeEnabled: Bool) -> Bool {
        audioBackgroundModeEnabled
    }

    /// The car does its own echo cancellation. Enabling Apple's voice-processing
    /// I/O unit on `.bluetoothHFP` / `.carAudio` can throw or assert.
    public static func shouldEnableVoiceProcessing(route: VoiceOutputRouteKind) -> Bool {
        switch route {
        case .bluetoothHFP:
            return false
        case .speaker, .headphones, .unknown:
            return true
        }
    }

    public static func shouldInstallTap(format: VoiceHardwareFormat?) -> Bool {
        format?.isValid == true
    }

    public static func shouldStartEngine(formatValid: Bool, routeSettled: Bool) -> Bool {
        formatValid && routeSettled
    }

    public static func shouldActivateSessionWhileEngineRunning() -> Bool {
        false
    }

    public static func allowsForcedSampleRate() -> Bool { false }
    public static func allowsForcedIOBufferDuration() -> Bool { false }

    public static func observerCallbackMustHopToMainActor() -> Bool { true }
}

/// Ring-buffer rules for the on-device audio breadcrumb log.
public enum VoiceAudioDebugLogPolicy {
    public static let maxEvents = 200
    public static let fileName = "anaiodyssey-audio-debug.log"

    public static func append<T>(_ existing: [T], event: T) -> [T] {
        var next = existing
        next.append(event)
        if next.count > maxEvents {
            next.removeFirst(next.count - maxEvents)
        }
        return next
    }

    public static func renderLine(
        timestamp: String,
        event: String,
        detail: String
    ) -> String {
        "\(timestamp) \(event) \(detail)"
    }
}

public struct VoiceAudioBreadcrumb: Sendable, Equatable {
    public var timestamp: String
    public var event: String
    public var detail: String

    public init(timestamp: String, event: String, detail: String) {
        self.timestamp = timestamp
        self.event = event
        self.detail = detail
    }

    public var line: String {
        VoiceAudioDebugLogPolicy.renderLine(timestamp: timestamp, event: event, detail: detail)
    }
}
