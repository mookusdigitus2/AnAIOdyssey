// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation
import AIModelOptions

/// Notification observers live here so the closures are not `@MainActor`.
/// Route / configuration / interruption are posted off the main thread;
/// touching MainActor state synchronously trips Swift 6 `dispatch_assert_queue`.
enum VoiceAudioNotificationBridge {
    static func install(engine: AVAudioEngine) {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            Task { @MainActor in
                VoiceDuplexEngine.shared.handleExternalGraphChange(event: .configurationChanged)
            }
        }

        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            // Our own setCategory posts .categoryChange; rebuilding on it
            // re-activated the session and looped on the main thread.
            // .oldDeviceUnavailable mid-reply stops playback (Replay brings it back).
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
            Task { @MainActor in
                VoiceDuplexEngine.shared.handleRouteChange(reasonRawValue: raw)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { note in
            let info = note.userInfo
            Task { @MainActor in
                VoiceAudioSession.invalidateSpokenActivation()
                VoiceDuplexEngine.shared.handleInterruptionUserInfo(info)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                VoiceAudioSession.invalidateSpokenActivation()
                VoiceDuplexEngine.shared.handleExternalGraphChange(event: .configurationChanged)
            }
        }
        #endif
    }

    private static let dropLock = NSLock()
    nonisolated(unsafe) private static var micBuffersDropped = false

    /// Read on the audio render thread: after Stop, tap buffers are dropped
    /// here before they ever hop to the main actor.
    nonisolated static func setMicBuffersDropped(_ dropped: Bool) {
        dropLock.lock()
        micBuffersDropped = dropped
        dropLock.unlock()
    }

    nonisolated static var areMicBuffersDropped: Bool {
        dropLock.lock()
        defer { dropLock.unlock() }
        return micBuffersDropped
    }

    nonisolated static func handleTapBuffer(_ buffer: AVAudioPCMBuffer) {
        if areMicBuffersDropped { return }
        let rms = VoiceDuplexEngine.rms(buffer)
        Task { @MainActor in
            VoiceDuplexEngine.shared.acceptTapBuffer(buffer, rms: rms)
        }
    }
}
