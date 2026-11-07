// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Event-driven voice control on iPhone: mic → Starting/Listening, Stop is
/// idle at once, Back during listening and during a spoken reply leaves the
/// chat at once. Screenshots are kept as attachments.
final class VoiceEventPipelineUITests: XCTestCase {
    private func launchIntoNewChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        app.launch()
        let chats = app.descendants(matching: .any).matching(identifier: "sidebar-chats").firstMatch
        if chats.waitForExistence(timeout: 3) { chats.tap() } else if app.tabBars.buttons["Chats"].exists { app.tabBars.buttons["Chats"].tap() }
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 8))
        app.buttons["new-chat-button"].tap()
        XCTAssertTrue(app.buttons["chat-voice-button"].waitForExistence(timeout: 8))
        return app
    }

    private func allowPermissions() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow' OR label == 'OK'")).firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() } else { break }
        }
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // Run with TEST_RUNNER_VOICE_SHOTS_DIR=/tmp/voice-event-shots to also
        // write PNGs on the host (the simulator shares the Mac filesystem).
        if let dir = ProcessInfo.processInfo.environment["VOICE_SHOTS_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back' OR label == 'Chats'")).firstMatch
    }

    /// Waits for the mic to reach listening (or report an error) after a tap.
    private func waitUntilVoiceSettles(_ voice: XCUIElement, timeout: TimeInterval = 10) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = voice.value as? String ?? ""
            if value == "Listening" || value == "Speaking" { return value }
            if value.isEmpty, voice.label == "Voice control" { return "idle" }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return voice.value as? String ?? ""
    }

    func testMicStopAndBackNeverWaitOnAudio() throws {
        #if os(iOS)
        continueAfterFailure = true
        let app = launchIntoNewChat()
        let voice = app.buttons["chat-voice-button"]
        guard voice.isEnabled else { throw XCTSkip("speech recognition unavailable on this simulator") }

        voice.tap()
        shot("1-mic-tapped")
        allowPermissions()
        let settled = waitUntilVoiceSettles(voice)
        shot("2-voice-\(settled)")

        // Stop: idle on the tap.
        if settled == "Listening" {
            let began = Date()
            voice.tap()
            let idle = NSPredicate(format: "label == 'Voice control'")
            expectation(for: idle, evaluatedWith: voice)
            // UI-level bound includes XCUITest tap/snapshot overhead; the
            // 50 ms bound on the Stop call itself is in VoiceSessionControllerTests.
            waitForExpectations(timeout: 3.0)
            print("VOICE-TIMING stop->idle \(Date().timeIntervalSince(began))s")
            shot("3-after-stop")

            // Mic again right away (during cleanup): starts, not grayed out.
            XCTAssertTrue(voice.isEnabled, "mic stays tappable while cleanup runs")
            voice.tap()
            _ = waitUntilVoiceSettles(voice)
        }

        // Back while listening: the chat list appears at once.
        let back = backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        let leaveBegan = Date()
        back.tap()
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 3), "Back must not wait on audio teardown")
        print("VOICE-TIMING back(listening)->list \(Date().timeIntervalSince(leaveBegan))s")
        XCTAssertFalse(app.buttons["chat-voice-button"].exists)
        shot("4-after-back-listening")
        XCTAssertEqual(app.state, .runningForeground)
        #endif
    }

    func testBackDuringSpokenReplyIsImmediate() throws {
        #if os(iOS)
        continueAfterFailure = true
        let app = launchIntoNewChat()
        let voice = app.buttons["chat-voice-button"]
        guard voice.isEnabled else { throw XCTSkip("speech recognition unavailable on this simulator") }
        voice.tap()
        allowPermissions()
        let settled = waitUntilVoiceSettles(voice)
        guard settled == "Listening" else { throw XCTSkip("voice did not start on this simulator: \(settled)") }

        // A typed message in voice mode is spoken back (mock LLM reply).
        let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Tell me a long story about the sea")
        app.buttons["chat-send-button"].tap()
        let speaking = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Speaking' OR label == 'Stop speaking'")).firstMatch
        _ = speaking.waitForExistence(timeout: 15)
        shot("5-speaking")

        let back = backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        let began = Date()
        back.tap()
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 3), "Back during speech must not wait")
        print("VOICE-TIMING back(speaking)->list \(Date().timeIntervalSince(began))s")
        shot("6-after-back-speaking")
        XCTAssertEqual(app.state, .runningForeground)
        #endif
    }

    /// Timing driver, skipped unless TEST_RUNNER_VOICE_BACK_RUNS is set: Back
    /// while listening and Back mid-reply, N times each. The tap-to-first-frame
    /// numbers come from the app's VoiceNav OSLog lines, not from these waits.
    func testBackTimingRepeated() throws {
        #if os(iOS)
        guard let raw = ProcessInfo.processInfo.environment["VOICE_BACK_RUNS"], let runs = Int(raw), runs > 0 else {
            throw XCTSkip("set TEST_RUNNER_VOICE_BACK_RUNS to run the Back timing loop")
        }
        continueAfterFailure = true
        let app = launchIntoNewChat()
        allowPermissionsAfterFirstMic(app)
        for mode in ["listening", "speaking"] {
            for run in 1...runs {
                if run > 1 || mode == "speaking" {
                    XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 5))
                    app.buttons["new-chat-button"].tap()
                }
                let voice = app.buttons["chat-voice-button"]
                XCTAssertTrue(voice.waitForExistence(timeout: 8))
                if waitUntilVoiceSettles(voice, timeout: 3) == "idle" { voice.tap() }
                guard waitUntilVoiceSettles(voice) == "Listening" else {
                    XCTFail("voice did not reach Listening (\(mode) run \(run))"); continue
                }
                if mode == "speaking" {
                    let composer = app.descendants(matching: .any).matching(identifier: "chat-composer").firstMatch
                    XCTAssertTrue(composer.waitForExistence(timeout: 5))
                    composer.tap()
                    composer.typeText(Self.longPrompt)
                    app.buttons["chat-send-button"].tap()
                    // Tap Back once audio is actually playing: the mic button's
                    // value is "Speaking" only after the first buffer is heard
                    // ("Stop speaking" alone also covers the synthesis wait).
                    let deadline = Date().addingTimeInterval(30)
                    var spoke = false
                    while Date() < deadline {
                        if (voice.value as? String) == "Speaking" { spoke = true; break }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    XCTAssertTrue(spoke, "reply never started speaking (run \(run))")
                }
                let back = backButton(app)
                XCTAssertTrue(back.waitForExistence(timeout: 3))
                back.tap()
                XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 6))
                print("VOICE-BACK-RUN \(mode) \(run) done")
                Thread.sleep(forTimeInterval: 1.5) // let the teardown finish before the next run
            }
        }
        #endif
    }

    /// The mock LLM echoes the prompt, so a long prompt is a ~15 s spoken reply.
    private static let longPrompt = "Tell me a long story about the sea, the lighthouse keeper who lived on the rocky island, the storms that came every winter, the ships that passed in the night, and the gulls that circled the tower every morning before the fishermen went out to sea"

    private func allowPermissionsAfterFirstMic(_ app: XCUIApplication) {
        let voice = app.buttons["chat-voice-button"]
        guard voice.waitForExistence(timeout: 8) else { return }
        voice.tap()
        allowPermissions()
    }
}
