// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Repro: active chat -> voice mode -> voice panel -> type a new voice -> Back.
final class VoicePanelAddVoiceUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM",
                                "-anaiodyssey.voice.elevenLabsAPIKey", "uitest-dummy-key",
                                "-anaiodyssey.voice.provider", "elevenlabs"]
        app.launch()
        return app
    }

    private func allowPermissions() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow' OR label == 'OK'")).firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() } else { break }
        }
    }

    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back' OR label == 'Chats' OR label == 'Voice'")).firstMatch
    }

    func testChatVoicePanelTypeNewVoiceThenBack() throws {
        #if os(iOS)
        let app = launch()
        let chats = app.descendants(matching: .any)["sidebar-chats"]
        if chats.waitForExistence(timeout: 3) { chats.tap() } else { app.tabBars.buttons["Chats"].tap() }
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 8))
        app.buttons["new-chat-button"].tap()
        let voice = app.buttons["chat-voice-button"]
        XCTAssertTrue(voice.waitForExistence(timeout: 8))
        voice.tap()
        allowPermissions()

        let settings = app.buttons["chat-voice-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "voice settings button missing in chat")
        settings.tap()
        let picker = app.buttons["spoken-reply-voice-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "voice picker missing in sheet")
        picker.tap()
        let field = app.textFields["voice-add-by-id-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "add-voice field missing")
        field.tap()
        field.typeText("My Narrator")
        let save = app.buttons["voice-add-save-button"]
        XCTAssertTrue(save.exists, "no Save for the new voice")
        XCTAssertFalse(save.isEnabled, "Save must wait for a successful lookup")
        XCTAssertTrue(app.buttons["voice-add-cancel-button"].exists)

        let back = backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "app died after Back")
        XCTAssertFalse(field.exists, "Back did not leave the voice list (hang)")
        let done = app.buttons["voice-settings-done-button"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "not back in the chat")
        XCTAssertTrue(voice.isHittable, "chat UI unresponsive after Back")
        #endif
    }
}
