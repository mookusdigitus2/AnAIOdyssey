// SPDX-License-Identifier: MIT
import Foundation

/// Classifies the active audio output so duplex speech can decide whether
/// the room (or the HFP SCO link) will leak TTS into the microphone.
public enum VoiceOutputRouteKind: String, Sendable, Equatable {
    /// Built-in speaker or receiver — room echo unless AEC is running.
    case speaker
    /// Wired headphones, USB headsets, AirPods / A2DP / LE — no speaker echo.
    case headphones
    /// Bluetooth HFP / car kits — electronic echo; keep speech barge-in off.
    case bluetoothHFP
    case unknown
}

/// Route rules for spoken conversation. Echo is handled by Apple's voice
/// processing (mic and TTS on one `AVAudioEngine`) plus playback state
/// (`VoiceListenGate`); transcripts are never compared with the reply.
/// Speech barge-in is off on routes where AEC is unreliable.
public enum VoiceEchoPolicy {
    // MARK: - Route

    /// `outputPortTypes` are `AVAudioSession.Port` raw values (`Speaker`,
    /// `Headphones`, `BluetoothA2DP`, `BluetoothHFP`, …). Names catch AirPods
    /// that drop to HFP during play-and-record but are still headphones.
    public static func routeKind(
        outputPortTypes: [String],
        outputPortNames: [String] = []
    ) -> VoiceOutputRouteKind {
        let types = Set(outputPortTypes.map { normalizePort($0) })
        let names = outputPortNames.joined(separator: " ").lowercased()

        if types.contains(where: { headphonePortTypes.contains($0) }) {
            return .headphones
        }
        if types.contains("bluetoothhfp") || types.contains("caraudio") {
            if looksLikeHeadphoneName(names) {
                return .headphones
            }
            return .bluetoothHFP
        }
        if types.contains("speaker") || types.contains("receiver") || types.contains("builtinspeaker") || types.contains("builtinreceiver") {
            return .speaker
        }
        if types.isEmpty {
            return .unknown
        }
        return .unknown
    }

    /// Speaker route: AEC on whenever the voice-processing unit is available.
    /// Headphones do not need it for room echo; leaving it on is harmless.
    public static func shouldEnableAcousticEchoCancellation(
        route: VoiceOutputRouteKind,
        voiceProcessingAvailable: Bool
    ) -> Bool {
        guard voiceProcessingAvailable else { return false }
        switch route {
        case .bluetoothHFP:
            // The car / HFP SCO link does its own AEC. Apple's voice-processing
            // I/O unit can throw or assert on that route.
            return false
        case .speaker, .unknown, .headphones:
            return true
        }
    }

    /// Speech barge-in (the recognizer may interrupt TTS) is on for the speaker
    /// when AEC is actually running, and on for headphones automatically.
    /// Bluetooth HFP stays off. Tap / stop-button barge-in is always allowed.
    public static func allowsSpeechBargeIn(
        route: VoiceOutputRouteKind,
        acousticEchoCancellationAvailable: Bool
    ) -> Bool {
        switch route {
        case .headphones:
            return true
        case .bluetoothHFP:
            return false
        case .speaker, .unknown:
            return acousticEchoCancellationAvailable
        }
    }

    /// Show the stop-button “Tap to interrupt” hint when talking over TTS
    /// will not be recognized.
    public static func shouldShowInterruptHint(speechBargeInEnabled: Bool) -> Bool {
        !speechBargeInEnabled
    }

    // MARK: - Private

    private static let headphonePortTypes: Set<String> = [
        "headphones",
        "bluetootha2dp",
        "bluetoothle",
        "usbaudio",
        "headsetmic",
        "lineout",
    ]

    private static func normalizePort(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    private static func looksLikeHeadphoneName(_ name: String) -> Bool {
        let needles = ["airpods", "airpod", "beats", "headphones", "headset", "earbuds", "earpods", "powerbeats"]
        return needles.contains { name.contains($0) }
    }
}
