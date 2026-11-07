// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AVFAudio
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

/// Build 17 on an iPhone Air: chat → voice on → Back froze the app. The audio log shows
/// the ElevenLabs socket closing (teardown) and then, one second later, a
/// route change rebuilding the graph and restarting the engine + mic tap with
/// voice processing — after the user had left. Teardown left `isConfigured`
/// true, so `handleExternalGraphChange` treated the dead graph as live.
@MainActor
final class VoiceLeaveChatTeardownTests: XCTestCase {
    func testRouteChangeAfterTeardownDoesNotRestartEngine() throws {
        let engine = VoiceDuplexEngine.shared
        try? engine.prepare(enableAEC: false)
        try? engine.start()
        VoiceAudioSession.endSpokenConversation()
        let rebuildsBefore = engine.graphRebuildCount

        engine.handleExternalGraphChange(event: .routeChanged)
        engine.handleExternalGraphChange(event: .configurationChanged)
        engine.handleExternalGraphChange(event: .interruptionEnded)

        XCTAssertEqual(engine.graphRebuildCount, rebuildsBefore, "no rebuild after the user left voice")
        XCTAssertFalse(engine.isRunningForTesting, "engine must stay stopped after teardown")
        XCTAssertFalse(engine.isTapInstalledForTesting, "mic tap must stay removed after teardown")
    }

    func testPrepareAfterTeardownStillWorks() throws {
        let engine = VoiceDuplexEngine.shared
        VoiceAudioSession.endSpokenConversation()
        let rebuildsBefore = engine.graphRebuildCount
        try? engine.prepare(enableAEC: false)
        XCTAssertGreaterThan(engine.graphRebuildCount, rebuildsBefore, "turning voice back on must rebuild")
        VoiceAudioSession.endSpokenConversation()
    }

    /// Leaving the chat must not run audio teardown synchronously in the Back
    /// tap: navigation flips first, teardown is scheduled afterwards.
    func testLeaveChatPolicyNavigatesBeforeTeardown() {
        XCTAssertEqual(VoiceLifecyclePolicy.leaveChatOrder, [.navigate, .teardownVoice])
    }

    func testAudioLogExportIsAReadableFile() throws {
        VoiceAudioDebugStore.append(event: "test.export", detail: "x")
        let url = try XCTUnwrap(VoiceAudioDebugStore.exportForSharing())
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
                      || url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("test.export"))
    }
}
