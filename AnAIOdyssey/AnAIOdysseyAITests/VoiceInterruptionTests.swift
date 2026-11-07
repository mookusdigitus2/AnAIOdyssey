// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AVFoundation
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
import AIModelOptions

@MainActor
final class VoiceInterruptionTests: XCTestCase {
    private func listeningController() async -> (VoiceSessionController, SlowFakeVoicePipeline) {
        let fake = SlowFakeVoicePipeline()
        fake.teardownDelay = 0.05
        let controller = VoiceSessionController(backend: fake)
        controller.onFailure = { _, _ in }
        controller.start()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .listening)
        return (controller, fake)
    }

    func testPolicyBeganStopsAndEndedNeverResumes() {
        XCTAssertEqual(VoiceInterruptionPolicy.command(began: true, shouldResume: false, sessionActive: true), .stopSession)
        XCTAssertEqual(VoiceInterruptionPolicy.command(began: true, shouldResume: false, sessionActive: false), .ignore)
        XCTAssertEqual(VoiceInterruptionPolicy.command(began: false, shouldResume: true, sessionActive: false), .ignore)
        XCTAssertEqual(VoiceInterruptionPolicy.command(began: false, shouldResume: true, sessionActive: true), .ignore)
    }

    func testInterruptionBeganStopsWithOneTeardownAndShowsNotice() async {
        let (controller, fake) = await listeningController()
        XCTAssertNil(controller.interruptionNotice)

        controller.handleInterruption(began: true, shouldResume: false)
        XCTAssertEqual(controller.state, .idle, "an incoming call stops voice at once")
        XCTAssertEqual(controller.interruptionNotice, "Voice paused for a call. Tap the mic to continue.")
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 1, "a single clean teardown")
        XCTAssertEqual(fake.events.filter { $0 == "silence" }.count, 1)

        // A second began (or a repeated notification) must not tear down again.
        controller.handleInterruption(began: true, shouldResume: false)
        await controller.waitUntilSettled()
        XCTAssertEqual(fake.teardownCount, 1)
    }

    func testInterruptionEndedWithShouldResumeDoesNotRestartTheMic() async {
        let (controller, fake) = await listeningController()
        controller.handleInterruption(began: true, shouldResume: false)
        await controller.waitUntilSettled()

        controller.handleInterruption(began: false, shouldResume: true)
        await controller.waitUntilSettled()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .idle, "the user taps the mic again; nothing auto-restarts")
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.interruptionNotice, VoiceInterruptionPolicy.pausedNotice, "notice stays until the mic is tapped")
    }

    func testMicTapClearsNoticeAndStarts() async {
        let (controller, fake) = await listeningController()
        controller.handleInterruption(began: true, shouldResume: false)
        controller.toggleMic()
        XCTAssertNil(controller.interruptionNotice)
        XCTAssertEqual(controller.state, .starting)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(fake.startCount, 2)
    }

    func testLeavingTheChatClearsNotice() async {
        let (controller, _) = await listeningController()
        controller.handleInterruption(began: true, shouldResume: false)
        XCTAssertNotNil(controller.interruptionNotice)
        controller.leave()
        XCTAssertNil(controller.interruptionNotice)
        await controller.waitUntilSettled()
    }

    func testInterruptionWhileIdleShowsNothing() async {
        let fake = SlowFakeVoicePipeline()
        let controller = VoiceSessionController(backend: fake)
        controller.handleInterruption(began: true, shouldResume: false)
        await controller.waitUntilSettled()
        XCTAssertNil(controller.interruptionNotice)
        XCTAssertEqual(fake.teardownCount, 0)
    }

    #if os(iOS)
    /// Fake AVAudioSession.interruptionNotification userInfo through the
    /// app-wide router to every registered controller.
    func testFakeInterruptionNotificationRoutesToControllers() async {
        let (controller, fake) = await listeningController()
        VoiceSessionControllers.registerForTesting(controller)
        defer { VoiceSessionControllers.unregisterForTesting(controller) }

        let began: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ]
        XCTAssertTrue(VoiceSessionControllers.routeInterruption(userInfo: began))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.interruptionNotice, VoiceInterruptionPolicy.pausedNotice)

        let ended: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]
        _ = VoiceSessionControllers.routeInterruption(userInfo: ended)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(fake.teardownCount, 1)
    }
    #endif
}
