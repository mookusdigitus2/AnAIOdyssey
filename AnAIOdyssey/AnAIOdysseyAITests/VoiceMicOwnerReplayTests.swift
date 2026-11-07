// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

@MainActor
final class VoiceMicOwnerReplayTests: XCTestCase {
    func testReplayWithoutCachedAudioReportsFalse() {
        let client = ElevenLabsWebSocketTTSClient()
        XCTAssertFalse(client.canReplayLastReply)
        XCTAssertFalse(client.replayLastReply())
    }
}

@MainActor
final class VoiceEnginePlayGuardTests: XCTestCase {
    /// "Engine is not running... Cannot play yet!": after the engine stopped
    /// on its own (config change / interruption), scheduling audio must
    /// restart it before play instead of trusting a stale isRunning flag.
    func testScheduleRestartsEngineStoppedBehindOurBack() throws {
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        try? engine.start()
        engine.stopEngineBehindOurBackForTesting()
        XCTAssertFalse(engine.isEngineActuallyRunning)
        engine.schedule(pcmData: Data(count: 4_800), sampleRate: 24_000)
        XCTAssertTrue(engine.isEngineActuallyRunning)
        engine.stopPlayback()
    }
}
