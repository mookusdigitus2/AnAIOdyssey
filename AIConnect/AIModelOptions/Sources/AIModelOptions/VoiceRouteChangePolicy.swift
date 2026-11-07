// SPDX-License-Identifier: MIT
import Foundation

/// What the voice engine does with an `AVAudioSession.routeChangeNotification`.
/// Following Apple's guidance, losing the output device (headphones unplugged, car
/// Bluetooth dropped) stops the reply instead of letting it continue out of the speaker;
/// the chat's Replay button plays it again.
public enum VoiceRouteChangeResponse: Equatable, Sendable {
    case ignore
    case rebuild
    case stopPlaybackOfferReplay
}

public enum VoiceRouteChangePolicy {
    static let oldDeviceUnavailable: UInt = 2  // AVAudioSession.RouteChangeReason.oldDeviceUnavailable
    static let categoryChange: UInt = 3        // our own setCategory

    public static let stoppedMessage = "Your headphones or car audio disconnected, so I stopped. Tap Replay to hear it again."

    public static func response(reasonRawValue: UInt?, hasPendingPlayback: Bool) -> VoiceRouteChangeResponse {
        switch reasonRawValue {
        case categoryChange: return .ignore
        case oldDeviceUnavailable: return hasPendingPlayback ? .stopPlaybackOfferReplay : .rebuild
        default: return .rebuild
        }
    }
}
