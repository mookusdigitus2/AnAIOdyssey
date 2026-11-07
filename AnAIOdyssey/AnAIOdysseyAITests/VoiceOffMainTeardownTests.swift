// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// The real engine path behind the controller: one teardown per Stop, run on
/// the audio queue (not main), engine stopped and tap removed before the
/// session is deactivated so other apps' audio can resume.
@MainActor
final class VoiceOffMainTeardownTests: XCTestCase {
    func testAsyncEndTearsDownOffMainAndDeactivatesLast() async throws {
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        try? engine.start()

        await VoiceAudioSession.endSpokenConversationAsync()

        XCTAssertEqual(engine.lastTeardownRanOnMainThread, false, "engine.stop/removeTap/setActive must run off main")
        XCTAssertFalse(engine.isRunningForTesting)
        XCTAssertFalse(engine.isTapInstalledForTesting)
        let steps = engine.lastTeardownSteps
        #if os(iOS)
        XCTAssertEqual(steps.last, "session.deactivate", "deactivate must be the last step: \(steps)")
        #endif
        if let stop = steps.firstIndex(of: "engine.stop"), let deactivate = steps.firstIndex(of: "session.deactivate") {
            XCTAssertLessThan(stop, deactivate)
        }
        if let tap = steps.firstIndex(of: "tap.remove"), let deactivate = steps.firstIndex(of: "session.deactivate") {
            XCTAssertLessThan(tap, deactivate)
        }
    }

    func testCompositeEndSpokenConversationTearsDownEngineOnce() {
        let defaults = UserDefaults(suiteName: "voice-teardown-once-\(UUID().uuidString)")!
        let composite = CompositeVoiceService(
            settings: AgentRegistrySettings(defaults: defaults),
            providerSettings: ProviderSettings(defaults: defaults)
        )
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        let before = engine.teardownCount
        composite.endSpokenConversation()
        XCTAssertEqual(engine.teardownCount - before, 1, "one Stop used to tear the engine down once per provider")
    }

    func testCompositeAsyncEndTearsDownOnceOffMain() async {
        let defaults = UserDefaults(suiteName: "voice-teardown-async-\(UUID().uuidString)")!
        let composite = CompositeVoiceService(
            settings: AgentRegistrySettings(defaults: defaults),
            providerSettings: ProviderSettings(defaults: defaults)
        )
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        let before = engine.teardownCount
        await composite.endSpokenConversationAsync()
        XCTAssertEqual(engine.teardownCount - before, 1)
        XCTAssertEqual(engine.lastTeardownRanOnMainThread, false)
    }

    func testSilenceNowDropsMicBuffersUntilNextPrepare() throws {
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        var delivered = 0
        engine.onMicBuffer = { _ in delivered += 1 }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160

        engine.silenceNow()
        engine.acceptTapBuffer(buffer, rms: 0.5)
        XCTAssertEqual(delivered, 0, "after Stop, mic audio must be ignored at once")
        XCTAssertEqual(engine.currentMicRMS, 0)

        try? engine.prepare(enableAEC: false)
        engine.onMicBuffer = { _ in delivered += 1 }
        engine.acceptTapBuffer(buffer, rms: 0.5)
        XCTAssertEqual(delivered, 1, "a new session takes mic audio again")
        VoiceAudioSession.endSpokenConversation()
    }
}
