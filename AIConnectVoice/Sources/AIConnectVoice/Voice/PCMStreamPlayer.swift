// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation

/// Plays raw PCM Int16 mono buffers through the shared duplex engine.
@MainActor
final class PCMStreamPlayer {
    private let sampleRate: Double
    private var didNotifyFirstSchedule = false
    var onFirstBufferScheduled: (() -> Void)?

    init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    func prime() throws {
        try VoiceDuplexEngine.shared.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        VoiceDuplexEngine.shared.onFirstPlayback = { [weak self] in
            self?.notifyFirstSchedule()
        }
        VoiceDuplexEngine.shared.primeSilence()
    }

    func start() throws {
        try VoiceDuplexEngine.shared.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        VoiceDuplexEngine.shared.onFirstPlayback = { [weak self] in
            self?.notifyFirstSchedule()
        }
        try VoiceDuplexEngine.shared.start()
    }

    func schedule(pcmData: Data) {
        if VoiceDuplexEngine.shared.onFirstPlayback == nil {
            VoiceDuplexEngine.shared.onFirstPlayback = { [weak self] in
                self?.notifyFirstSchedule()
            }
        }
        try? VoiceDuplexEngine.shared.start()
        VoiceDuplexEngine.shared.schedule(pcmData: pcmData, sampleRate: sampleRate)
    }

    func waitUntilFinished() async {
        await VoiceDuplexEngine.shared.waitUntilFinished()
    }

    func stop(teardownEngine: Bool = false) {
        VoiceDuplexEngine.shared.stopPlayback()
        didNotifyFirstSchedule = false
        if teardownEngine, !VoiceAudioSession.conversationActive {
            VoiceDuplexEngine.shared.teardown()
        }
    }

    func resetFirstScheduleFlag() {
        didNotifyFirstSchedule = false
        VoiceDuplexEngine.shared.resetFirstPlaybackFlag()
    }

    private func notifyFirstSchedule() {
        guard !didNotifyFirstSchedule else { return }
        didNotifyFirstSchedule = true
        onFirstBufferScheduled?()
    }
}
