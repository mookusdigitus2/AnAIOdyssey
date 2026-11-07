// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

/// Voice mode froze the UI: every prepare/rebuild re-ran the synchronous
/// AVAudioSession setCategory/setActive on the main thread, and the
/// .categoryChange route notification it posted rebuilt the graph, which
/// activated the session again. Activation must be idempotent.
@MainActor
final class VoiceSessionLoopTests: XCTestCase {
    override func tearDown() async throws {
        VoiceAudioSession.endSpokenConversation()
    }

    func testRepeatedSpokenActivationAppliesSessionOnce() throws {
        #if os(iOS)
        VoiceAudioSession.deactivate()
        let before = VoiceAudioSession.spokenActivationCount
        for _ in 0..<5 {
            try? VoiceAudioSession.activateForSpokenConversation()
        }
        XCTAssertLessThanOrEqual(VoiceAudioSession.spokenActivationCount - before, 1)
        #endif
    }

    func testRepeatedPrepareDoesNotReactivateSessionOrBlock() throws {
        #if os(iOS)
        VoiceAudioSession.deactivate()
        try? VoiceAudioSession.activateForSpokenConversation()
        let before = VoiceAudioSession.spokenActivationCount
        let start = Date()
        for _ in 0..<5 {
            try? VoiceDuplexEngine.shared.prepare(enableAEC: true)
            try? VoiceAudioSession.activateForSpokenConversation()
        }
        XCTAssertEqual(VoiceAudioSession.spokenActivationCount, before)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        #endif
    }

    func testDeactivateAllowsReactivation() throws {
        #if os(iOS)
        try? VoiceAudioSession.activateForSpokenConversation()
        VoiceAudioSession.deactivate()
        XCTAssertFalse(VoiceAudioSession.spokenSessionActivated)
        #endif
    }
}
