// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

final class VoiceAddCancelPreviewUITests: XCTestCase {
    private func launch(provider: String, slowLookup: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM",
                                "-anaiodyssey.voice.elevenLabsAPIKey", "uitest-dummy-key",
                                "-anaiodyssey.voice.provider", provider]
        if slowLookup { app.launchEnvironment["UITEST_SLOW_VOICE_LOOKUP"] = "1" }
        app.launch()
        return app
    }

    private func openVoiceList(_ app: XCUIApplication) {
        let chats = app.descendants(matching: .any).matching(identifier: "sidebar-chats").firstMatch
        if chats.waitForExistence(timeout: 3) { chats.tap() } else { app.tabBars.buttons["Chats"].tap() }
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 8))
        app.buttons["new-chat-button"].tap()
        let voice = app.buttons["chat-voice-button"]
        XCTAssertTrue(voice.waitForExistence(timeout: 8))
        voice.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow' OR label == 'OK'")).firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() } else { break }
        }
        XCTAssertTrue(app.buttons["chat-voice-settings-button"].waitForExistence(timeout: 8))
        app.buttons["chat-voice-settings-button"].tap()
        XCTAssertTrue(app.buttons["spoken-reply-voice-picker"].waitForExistence(timeout: 8))
        app.buttons["spoken-reply-voice-picker"].tap()
    }

    private func back(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back' OR label == 'Voice'")).firstMatch
    }

    func testCancelEnabledDuringLookupAndBackIsImmediate() throws {
        #if os(iOS)
        let app = launch(provider: "elevenlabs", slowLookup: true)
        openVoiceList(app)
        let field = app.textFields["voice-add-by-id-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("21m00Tcm4TlvDq8ikWAM")
        let lookingUp = app.descendants(matching: .any)["voice-add-looking-up"]
        if !lookingUp.waitForExistence(timeout: 3) { print("TREEDUMP\n" + app.debugDescription) }
        XCTAssertTrue(lookingUp.exists, "no Looking up… status")
        let cancel = app.buttons["voice-add-cancel-button"]
        XCTAssertTrue(cancel.isEnabled, "Cancel must be enabled during a lookup")
        XCTAssertFalse(app.buttons["voice-add-save-button"].isEnabled, "Save waits for the lookup")
        cancel.tap()
        XCTAssertFalse(app.descendants(matching: .any)["voice-add-looking-up"].waitForExistence(timeout: 2))
        XCTAssertEqual(field.value as? String ?? "", "Voice ID")

        field.tap()
        field.typeText("21m00Tcm4TlvDq8ikWAM")
        XCTAssertTrue(app.descendants(matching: .any)["voice-add-looking-up"].waitForExistence(timeout: 3))
        let b = back(app)
        XCTAssertTrue(b.waitForExistence(timeout: 3))
        let start = Date()
        b.tap()
        XCTAssertTrue(app.buttons["voice-settings-done-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(field.exists, "Back blocked by the running lookup")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        #endif
    }

    func testLookupTimeoutShowsError() throws {
        #if os(iOS)
        let app = launch(provider: "elevenlabs", slowLookup: true)
        openVoiceList(app)
        let field = app.textFields["voice-add-by-id-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("21m00Tcm4TlvDq8ikWAM")
        XCTAssertTrue(app.descendants(matching: .any)["voice-add-looking-up"].waitForExistence(timeout: 3))
        let timedOut = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Lookup timed out'")).firstMatch
        XCTAssertTrue(timedOut.waitForExistence(timeout: 15), "lookup hung without a timeout error")
        XCTAssertFalse(app.descendants(matching: .any)["voice-add-looking-up"].exists)
        XCTAssertTrue(app.buttons["voice-add-cancel-button"].isEnabled)
        XCTAssertFalse(app.buttons["voice-add-save-button"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        #endif
    }

    func testBackDuringPreviewIsImmediate() throws {
        #if os(iOS)
        let app = launch(provider: "system", slowLookup: false)
        openVoiceList(app)
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice-preview-'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "no preview button")
        preview.tap()
        let b = back(app)
        XCTAssertTrue(b.waitForExistence(timeout: 3))
        let start = Date()
        b.tap()
        XCTAssertTrue(app.buttons["voice-settings-done-button"].waitForExistence(timeout: 3), "Back blocked by preview")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        app.buttons["voice-settings-done-button"].tap()
        XCTAssertTrue(app.buttons["chat-voice-button"].waitForExistence(timeout: 5))
        #endif
    }
}
