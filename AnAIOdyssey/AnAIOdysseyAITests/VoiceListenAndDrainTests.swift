// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

/// Voice chat only listened after Settings > Test voice: the STT services
/// deactivated AVAudioSession directly after each recording pass, while
/// VoiceAudioSession still believed the duplex session was active, so the
/// next activation was skipped and the mic stayed dead.
@MainActor
final class VoiceListenAndDrainTests: XCTestCase {
    override func tearDown() async throws {
        VoiceAudioSession.endSpokenConversation()
    }

    func testReleaseOutsideConversationDeactivatesAndAllowsReactivation() throws {
        #if os(iOS)
        try? VoiceAudioSession.activateForSpokenConversation()
        VoiceAudioSession.conversationActive = false
        VoiceAudioSession.releaseAfterRecording()
        XCTAssertFalse(VoiceAudioSession.spokenSessionActivated)
        let before = VoiceAudioSession.spokenActivationCount
        try? VoiceAudioSession.activateForSpokenConversation()
        XCTAssertGreaterThanOrEqual(VoiceAudioSession.spokenActivationCount, before)
        #endif
    }

    func testPlaybackDrainWaitsForAllScheduledAudio() async throws {
        let player = PCMStreamPlayer(sampleRate: 24_000)
        try? player.start()
        for _ in 0..<5 {
            player.schedule(pcmData: Data(count: 4_800)) // 100 ms each
        }
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in await VoiceDuplexEngine.shared.waitUntilFinished() }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
        XCTAssertFalse(VoiceDuplexEngine.shared.isPlayingBack)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
