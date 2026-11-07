// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation

/// Soft earcon played the moment listening ends so the user knows the turn
/// flipped to thinking without staring at the status line.
public enum VoiceListeningCue {
    public static let sampleRate: Double = 22_050
    public static let duration: Double = 0.16
    public static let frequency: Double = 392  // G4: an octave below the old G5
    public static let peak: Double = 0.08  // half the old gain
    /// AVAudioPlayer volume when voice control is off.
    public static let playerVolume: Float = 0.175

    /// The cue never plays over (or queues behind) reply audio, e.g. while a
    /// reply is paused on the "continue?" prompt.
    public static func shouldPlay(replyAudioPending: Bool) -> Bool { !replyAudioPending }

    @MainActor
    public static func play() {
        #if os(macOS) || os(iOS)
        guard shouldPlay(replyAudioPending: VoiceDuplexEngine.shared.hasPendingPlayback),
              let pcm = tonePCM() else { return }
        if VoiceAudioSession.conversationActive {
            VoiceDuplexEngine.shared.scheduleCue(pcmData: pcm, sampleRate: sampleRate)
        } else if let wav = toneWAV() {
            CuePlayer.shared.play(wav)
        }
        #endif
    }

    public static func tonePCM() -> Data? {
        let frameCount = Int(sampleRate * duration)
        guard frameCount > 0 else { return nil }
        var pcm = Data(count: frameCount * 2)
        pcm.withUnsafeMutableBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<frameCount {
                let time = Double(index) / sampleRate
                let fadeIn = min(1, Double(index) / (sampleRate * 0.012))
                let fadeOut = min(1, Double(frameCount - index) / (sampleRate * 0.03))
                let envelope = fadeIn * fadeOut
                let value = sin(2 * Double.pi * frequency * time) * peak * envelope
                samples[index] = Int16((value * Double(Int16.max)).rounded())
            }
        }
        return pcm
    }

    public static func toneWAV() -> Data? {
        guard let pcm = tonePCM() else { return nil }
        return wavHeader(dataSize: pcm.count) + pcm
    }

    private static func wavHeader(dataSize: Int) -> Data {
        var header = Data()
        func appendASCII(_ string: String) {
            header.append(contentsOf: string.utf8)
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            header.append(Data(bytes: &little, count: 2))
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            header.append(Data(bytes: &little, count: 4))
        }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2)
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        return header
    }
}

#if os(macOS) || os(iOS)
@MainActor
private final class CuePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = CuePlayer()
    private var player: AVAudioPlayer?

    func play(_ data: Data) {
        player?.stop()
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.volume = VoiceListeningCue.playerVolume
        player?.prepareToPlay()
        player?.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
            }
        }
    }
}
#endif
