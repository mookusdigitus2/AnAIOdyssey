// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation
import AIModelOptions

/// Keeps AVAudioSession transitions safe while switching between mic capture and TTS playback.
@MainActor
public enum VoiceAudioSession {
    /// Once a spoken conversation is armed we stay on play-and-record so the
    /// first reply does not pay a category-change tax.
    public static var conversationActive = false

    /// Tests force the echo check's "session is voiceChat" answer.
    public nonisolated(unsafe) static var voiceChatOverrideForTesting: Bool?

    /// True once play-and-record/voiceChat has been applied and activated.
    /// Re-applying it is a synchronous, main-thread-blocking IPC call and also
    /// posts a route change, which used to rebuild the graph, which activated
    /// again: a feedback loop that froze the UI when voice mode started.
    static private(set) var spokenSessionActivated = false
    /// Number of real setCategory/setActive passes (for tests and debugging).
    static private(set) var spokenActivationCount = 0

    /// Serial queue for blocking AVAudioSession IPC (setCategory/setActive/
    /// overrides) and voice control's engine teardown. Running those on the main thread is what logs
    /// "This method can lead to UI unresponsiveness" and froze voice mode.
    public nonisolated static let audioQueue = DispatchQueue(label: "com.example.anaiodyssey.audio-session", qos: .userInitiated)

    public nonisolated static func runOnAudioQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            audioQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Voice control's teardown: one engine stop, tap removal and session
    /// deactivation, in that order, on `audioQueue`. Never blocks main.
    public static func endSpokenConversationAsync() async {
        conversationActive = false
        spokenSessionActivated = false
        await VoiceDuplexEngine.shared.teardownOffMain(deactivateSession: true)
    }

    /// A graph rebuild ran the policy's `.activateSession` on the audio queue.
    public static func noteSpokenActivation(applied: Bool) {
        conversationActive = true
        guard applied else { return }
        spokenSessionActivated = true
        spokenActivationCount += 1
    }

    #if os(iOS)
    /// The spoken-conversation session: play-and-record in voiceChat mode,
    /// so Apple's echo cancellation runs (req. 15).
    public nonisolated static let spokenConversationCategory: AVAudioSession.Category = .playAndRecord
    public nonisolated static let spokenConversationMode: AVAudioSession.Mode = .voiceChat
    /// Test hook: whether the last async session configuration ran on main.
    static private(set) var lastSessionWorkRanOnMainThread: Bool?
    /// HFP (`.allowBluetooth` / `.allowBluetoothHFP`) for car kits, A2DP for
    /// headphones, speaker fallback. Matches `VoiceAudioSessionPolicy`.
    public static var spokenConversationOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetoothHFP,
            .allowBluetoothA2DP,
        ]
        options.insert(.allowBluetoothHFP)
        return options
    }

    /// Optimized for ElevenLabs / MP3 playback through the device speaker.
    public static func prepareForPlayback() throws {
        if conversationActive {
            // Already configured and active: no main-thread IPC.
            if spokenSessionActivated { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                applyPreferredOutputPort()
            } catch {
                VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
                throw error
            }
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            spokenSessionActivated = false
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            throw error
        }
    }

    /// Off-main variant for UI callers (voice preview). The session IPC runs
    /// on `audioQueue` so tapping play, then Back, never waits on audio setup.
    public static func prepareForPlaybackAsync() async throws {
        if conversationActive, spokenSessionActivated { return }
        let duplex = conversationActive
        if !duplex { spokenSessionActivated = false }
        do {
            try await runOnAudioQueue {
                let session = AVAudioSession.sharedInstance()
                if !duplex, session.category != .playback || session.mode != .spokenAudio {
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
                }
                try session.setActive(true, options: [])
            }
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            throw error
        }
    }

    /// Optimized for on-device speech recognition after TTS finishes.
    public static func prepareForRecording() throws {
        if conversationActive {
            // Already configured and active: no main-thread IPC.
            if spokenSessionActivated { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                applyPreferredOutputPort()
            } catch {
                VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
                throw error
            }
            return
        }
        try activateForSpokenConversation()
    }

    /// `prepareForRecording` without main-thread IPC: an already-active
    /// duplex session is a no-op, anything else activates on the audio queue.
    public static func prepareForRecordingAsync() async throws {
        if conversationActive, spokenSessionActivated { return }
        try await activateForSpokenConversationAsync()
    }

    /// Initial voice-control session before the first utterance.
    public static func activateForVoiceInteraction() throws {
        try activateForSpokenConversation()
    }

    /// Duplex session: play-and-record + voiceChat so Apple AEC can run.
    /// `setActive` is never force-tried — failures surface as a short banner.
    /// The engine must be stopped first: HFP's SCO link opens on activate and
    /// a running graph plus a mid-flight category change is what crashes the car path.
    public static func activateForSpokenConversation() throws {
        let session = AVAudioSession.sharedInstance()
        // Idempotent check FIRST. This used to stop the engine before checking,
        // so every redundant call (STT pass start, heal, prepareForRecording)
        // killed the live graph after recognition had started: device log
        // shows 5x "engine.stop session-change" per voice start.
        if spokenSessionActivated,
           session.category == .playAndRecord,
           session.mode == .voiceChat {
            conversationActive = true
            return
        }
        if VoiceDuplexEngine.shared.isEngineRunning,
           !VoiceLifecyclePolicy.shouldActivateSessionWhileEngineRunning() {
            VoiceDuplexEngine.shared.stopEngineForSessionChange()
        }
        conversationActive = true
        do {
            try session.setCategory(
                spokenConversationCategory,
                mode: spokenConversationMode,
                options: spokenConversationOptions
            )
            try session.setActive(true, options: [])
            spokenSessionActivated = true
            spokenActivationCount += 1
            applyPreferredOutputPort()
            VoiceAudioDebugStore.append(
                event: "session.activate",
                detail: "playAndRecord/voiceChat \(VoiceRouteMonitor.debugDescription())"
            )
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            VoiceAudioDebugStore.append(event: "session.activate.failed", detail: "\(error)")
            throw error
        }
    }

    /// Async duplex activation: same rules as `activateForSpokenConversation`,
    /// but the AVAudioSession calls run on `audioQueue`, never on the main thread.
    /// Skipped entirely when the session is already configured.
    public static func activateForSpokenConversationAsync() async throws {
        if VoiceDuplexEngine.shared.isEngineRunning,
           !VoiceLifecyclePolicy.shouldActivateSessionWhileEngineRunning(),
           !spokenSessionActivated {
            await VoiceDuplexEngine.shared.stopEngineForSessionChangeAsync()
        }
        conversationActive = true
        if spokenSessionActivated { return }
        let options = spokenConversationOptions
        let preferSpeaker = VoiceRouteMonitor.currentKind() == .speaker
        do {
            let ranOnMain = try await runOnAudioQueue { () -> Bool in
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord || session.mode != .voiceChat
                    || session.categoryOptions != options {
                    try session.setCategory(spokenConversationCategory, mode: spokenConversationMode, options: options)
                }
                try session.setActive(true, options: [])
                try? session.overrideOutputAudioPort(preferSpeaker ? .speaker : .none)
                return Thread.isMainThread
            }
            lastSessionWorkRanOnMainThread = ranOnMain
            spokenSessionActivated = true
            spokenActivationCount += 1
            VoiceAudioDebugStore.append(event: "session.activate.async", detail: "playAndRecord/voiceChat")
        } catch {
            VoiceDuplexEngine.shared.reportAudioIssue(VoiceAudioIssueMessage.sessionActivationFailed)
            VoiceAudioDebugStore.append(event: "session.activate.failed", detail: "\(error)")
            throw error
        }
    }

    public static func applyPreferredOutputPort() {
        let kind = VoiceRouteMonitor.currentKind()
        if kind == .speaker {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } else {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        }
    }

    public static func endSpokenConversation() {
        conversationActive = false
        VoiceDuplexEngine.shared.teardown()
        deactivate()
    }

    /// Fully releases the audio session when voice control ends.
    /// Called when a recording pass ends. During a spoken conversation the
    /// duplex session must stay active: deactivating it behind
    /// `spokenSessionActivated`'s back made the next activation a no-op, so
    /// the mic never came back until Settings > Test voice re-activated it.
    public static func releaseAfterRecording() {
        if conversationActive { return }
        deactivate()
    }

    /// Forces the next activation to re-apply the session (after an
    /// interruption or media-services reset).
    public static func invalidateSpokenActivation() {
        spokenSessionActivated = false
    }

    public static func deactivate() {
        conversationActive = false
        spokenSessionActivated = false
        // Off the main thread; the serial queue keeps it ordered before any
        // later activation.
        audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    #else
    public static func prepareForPlayback() throws {}
    public static func prepareForPlaybackAsync() async throws {}
    public static func prepareForRecording() throws {}
    public static func prepareForRecordingAsync() async throws {}
    public static func activateForVoiceInteraction() throws {
        conversationActive = true
    }
    public static func activateForSpokenConversation() throws {
        conversationActive = true
    }
    public static func activateForSpokenConversationAsync() async throws {
        conversationActive = true
    }
    public static func invalidateSpokenActivation() {}
    public static func releaseAfterRecording() {}
    public static func applyPreferredOutputPort() {}
    public static func endSpokenConversation() {
        conversationActive = false
        VoiceDuplexEngine.shared.teardown()
    }
    public static func deactivate() {
        conversationActive = false
    }
    #endif
}
