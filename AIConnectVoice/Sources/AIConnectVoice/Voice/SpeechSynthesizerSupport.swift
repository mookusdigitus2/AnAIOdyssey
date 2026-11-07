// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation

/// Queues `AVSpeechSynthesizer` utterances and can await full drain or a single speak.
@MainActor
final class AwaitableSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    var voiceIdentifier: () -> String = { "" }
    private let synthesizer = AVSpeechSynthesizer()
    private var singleShotContinuation: CheckedContinuation<Void, Never>?
    private var utteranceCompletions: [ObjectIdentifier: () -> Void] = [:]
    private var pendingCount = 0
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    var onUtteranceStarted: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        Self.active = self
    }

    fileprivate static weak var active: AwaitableSpeechSynthesizer?

    fileprivate func handleHoppedWrite(_ buffer: AVAudioBuffer?, utteranceID: ObjectIdentifier) {
        if let pcm = buffer as? AVAudioPCMBuffer {
            try? VoiceDuplexEngine.shared.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
            VoiceDuplexEngine.shared.schedule(buffer: pcm)
            onUtteranceStarted?()
        } else if let utterance = utteranceCompletions.keys.first(where: { $0 == utteranceID }) {
            _ = utterance
            if let completion = utteranceCompletions.removeValue(forKey: utteranceID) {
                completion()
            }
            resumeSingleShot()
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || pendingCount > 0
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.singleShotContinuation = continuation
            self.enqueue(trimmed)
        }
    }

    /// Enqueues an utterance; buffers play through the duplex engine (AEC).
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        #if os(macOS) || os(iOS)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = resolvedVoice()
        pendingCount += 1
        utteranceCompletions[ObjectIdentifier(utterance)] = { [weak self] in
            self?.noteUtteranceFinished()
        }
        synthesizer.write(utterance) { buffer in
            hopSpeechWrite(buffer, utteranceID: ObjectIdentifier(utterance))
        }
        #endif
    }

    /// Suspends until the synthesizer queue is empty.
    func waitUntilFinished() async {
        if pendingCount == 0 && !synthesizer.isSpeaking {
            await VoiceDuplexEngine.shared.waitUntilFinished()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainContinuations.append(continuation)
            if pendingCount == 0 && !synthesizer.isSpeaking {
                resumeDrainWaiters()
            }
        }
        await VoiceDuplexEngine.shared.waitUntilFinished()
    }

    func preloadVoice() {
        #if os(macOS) || os(iOS)
        _ = AVSpeechSynthesisVoice.speechVoices()
        _ = resolvedVoice()
        #endif
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        VoiceDuplexEngine.shared.stopPlayback()
        utteranceCompletions.removeAll()
        pendingCount = 0
        resumeSingleShot()
        resumeDrainWaiters()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onUtteranceStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.complete(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.complete(utterance)
        }
    }

    private func complete(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        if let completion = utteranceCompletions.removeValue(forKey: id) {
            completion()
        }
        resumeSingleShot()
    }

    private func noteUtteranceFinished() {
        if pendingCount > 0 {
            pendingCount -= 1
        }
        if pendingCount == 0 {
            resumeDrainWaiters()
        }
    }

    private func resumeSingleShot() {
        let continuation = singleShotContinuation
        singleShotContinuation = nil
        continuation?.resume()
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let identifier = voiceIdentifier().trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
    }

    private func resumeDrainWaiters() {
        let waiters = drainContinuations
        drainContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

nonisolated func hopSpeechWrite(_ buffer: AVAudioBuffer?, utteranceID: ObjectIdentifier) {
    Task { @MainActor in
        AwaitableSpeechSynthesizer.active?.handleHoppedWrite(buffer, utteranceID: utteranceID)
    }
}
