// SPDX-License-Identifier: MIT
import Foundation
import AIConnect

/// Public handle on the shared duplex engine for apps that drive their own
/// voice state (other host apps). Mic and speech share one engine, so the echo
/// canceller always has the playback reference.
@MainActor
public enum SharedVoiceAudio {
    /// Same setup as `SystemVoiceService.prepareSpokenConversation`: spoken
    /// session category and the duplex engine with AEC on routes that allow it.
    public static func prepareSpokenConversation() async {
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? await VoiceDuplexEngine.shared.prepareAsync(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
    }

    /// Ends listening and releases the audio session off the main thread,
    /// with session deactivation last.
    public static func endSpokenConversation(input: SystemSpeechInputService) async {
        input.endContinuousListening(releaseSession: false)
        await VoiceAudioSession.endSpokenConversationAsync()
    }

    /// Instant, cheap stop: playback cut and mic buffers ignored.
    public static func silenceNow() { VoiceDuplexEngine.shared.silenceNow() }

    /// Latest mic RMS from the shared engine, for a listening level ring.
    public static var micLevel: Double { VoiceDuplexEngine.shared.currentMicRMS }
    public static var hasPendingPlayback: Bool { VoiceDuplexEngine.shared.hasPendingPlayback }
    public static func pausePlayback() { VoiceDuplexEngine.shared.pausePlayback() }
    public static func resumePlayback() { VoiceDuplexEngine.shared.resumePlayback() }
    public static func stopPlayback() { VoiceDuplexEngine.shared.stopPlayback() }
}
