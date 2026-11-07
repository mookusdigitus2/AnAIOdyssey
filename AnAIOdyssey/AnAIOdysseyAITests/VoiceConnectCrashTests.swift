// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

/// Reproduces the "mic button crashes voice chat" abort:
/// ElevenLabsWebSocketTTSClient.connect -> PCMStreamPlayer.prime()
/// -> VoiceDuplexEngine.primeSilence() -> AVAudioPlayerNode.scheduleBuffer
/// raised NSInvalidArgumentException when the silence buffer used the mixer's
/// output format instead of the player node's format. An ObjC exception
/// aborts the test process, so a regression shows up as a crashed test.
@MainActor
final class VoiceConnectCrashTests: XCTestCase {
    func testPrimeThenScheduleElevenLabsPCMDoesNotCrash() throws {
        let player = PCMStreamPlayer(sampleRate: 24_000)
        try? player.prime()
        // 100 ms of 24 kHz mono Int16 silence, the ElevenLabs stream format.
        player.schedule(pcmData: Data(count: 4_800))
        try? player.prime()
    }

    func testPrimeSilenceMatchesPlayerNodeFormat() throws {
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: true)
        engine.primeSilence()
        engine.primeSilence()
    }
}
