// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

/// Fresh process, straight into voice mode, no Settings > Test voice first.
/// Mirrors ChatDetailView.toggleVoiceControl: prepareSpokenConversation
/// (activate session + engine.prepare) then begin listening.
@MainActor
final class VoiceColdStartTests: XCTestCase {
    func testColdStartVoiceModeStartsEngineTapAndDeliversMicBuffers() async throws {
        #if os(iOS)
        let engine = VoiceDuplexEngine.shared
        try? VoiceAudioSession.activateForSpokenConversation()
        try? engine.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        // What SpeechInputService.startAudioCaptureIfNeeded does next.
        try? VoiceAudioSession.prepareForRecording()
        try? engine.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)

        var buffers = 0
        engine.onMicBuffer = { _ in buffers += 1 }
        for _ in 0..<30 where buffers == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = AVAudioSession.sharedInstance()
        print("COLDSTART category=\(session.category.rawValue) mode=\(session.mode.rawValue) running=\(engine.isEngineActuallyRunning) tap=\(engine.isTapInstalledForTesting) buffers=\(buffers) issue=\(engine.lastAudioIssue ?? "nil")")
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(engine.isEngineActuallyRunning, "engine not running on cold start")
        XCTAssertTrue(engine.isTapInstalledForTesting, "mic tap not installed on cold start")
        XCTAssertGreaterThan(buffers, 0, "no mic buffers on cold start")
        engine.onMicBuffer = nil
        VoiceAudioSession.endSpokenConversation()
        #endif
    }

    /// Stale state (session flagged active, engine stopped behind our back):
    /// voice mode must heal itself without Settings > Test voice.
    func testVoiceModeHealsCaptureWithoutTestVoice() async throws {
        #if os(iOS)
        let engine = VoiceDuplexEngine.shared
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? engine.prepare(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        engine.stopEngineBehindOurBackForTesting()
        XCTAssertFalse(engine.isEngineActuallyRunning)
        let ready = await engine.ensureCaptureReady(enableAEC: VoiceRouteMonitor.shouldEnableAEC)
        XCTAssertTrue(ready)
        XCTAssertTrue(engine.isEngineActuallyRunning)
        XCTAssertTrue(engine.isTapInstalledForTesting)
        VoiceAudioSession.endSpokenConversation()
        #endif
    }

    /// AVAudioSession configuration must not run on the main thread, and is
    /// skipped when already configured.
    func testAsyncSessionActivationRunsOffMainAndOnce() async throws {
        #if os(iOS)
        VoiceAudioSession.deactivate()
        try await VoiceAudioSession.activateForSpokenConversationAsync()
        XCTAssertEqual(VoiceAudioSession.lastSessionWorkRanOnMainThread, false)
        let count = VoiceAudioSession.spokenActivationCount
        try await VoiceAudioSession.activateForSpokenConversationAsync()
        try await VoiceAudioSession.activateForSpokenConversationAsync()
        XCTAssertEqual(VoiceAudioSession.spokenActivationCount, count)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        VoiceAudioSession.endSpokenConversation()
        #endif
    }

    /// Voice start called prepare() ~5 times; each rebuilt the graph (engine
    /// stop + tap reinstall) after recognition had started. A second prepare
    /// with nothing changed must not rebuild.
    func testRepeatedPrepareDoesNotRebuildLiveGraph() async throws {
        #if os(iOS)
        let engine = VoiceDuplexEngine.shared
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? engine.prepare(enableAEC: true)
        XCTAssertTrue(engine.isEngineActuallyRunning)
        let rebuilds = engine.graphRebuildCount
        for _ in 0..<4 { try? engine.prepare(enableAEC: true) }
        XCTAssertEqual(engine.graphRebuildCount, rebuilds, "prepare rebuilt a live graph")
        XCTAssertTrue(engine.isEngineActuallyRunning)
        VoiceAudioSession.endSpokenConversation()
        #endif
    }

    /// Redundant sync activation (what every STT pass / heal calls) must not
    /// stop the running engine once the duplex session is live.
    func testRedundantSyncActivationDoesNotStopLiveEngine() async throws {
        #if os(iOS)
        let engine = VoiceDuplexEngine.shared
        try? await VoiceAudioSession.activateForSpokenConversationAsync()
        try? engine.prepare(enableAEC: true)
        XCTAssertTrue(engine.isEngineActuallyRunning)
        for _ in 0..<3 { try? VoiceAudioSession.activateForSpokenConversation() }
        XCTAssertTrue(engine.isEngineActuallyRunning, "redundant activation stopped the live engine")
        VoiceAudioSession.endSpokenConversation()
        #endif
    }
}
