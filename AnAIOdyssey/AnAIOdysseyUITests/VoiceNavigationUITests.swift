// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Push a chat, start voice mode, go back. A crash happened on the chat back
/// button with the voice changes; this drives that path repeatedly.
final class VoiceNavigationUITests: XCTestCase {
    func testStartVoiceThenBackOutOfChatDoesNotCrash() throws {
        #if os(iOS)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        for round in 0..<3 {
            let chats = app.descendants(matching: .any)["sidebar-chats"]
            if chats.waitForExistence(timeout: 3) { chats.tap() }
            else if app.tabBars.buttons["Chats"].exists { app.tabBars.buttons["Chats"].tap() }
            let newChat = app.buttons["new-chat-button"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 8), "round \(round): no new chat button")
            newChat.tap()

            let voice = app.buttons["chat-voice-button"]
            XCTAssertTrue(voice.waitForExistence(timeout: 8), "round \(round): no voice button")
            if voice.isEnabled { voice.tap() }
            sleep(1)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<3 {
                let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow' OR label == 'OK'")).firstMatch
                if allow.waitForExistence(timeout: 2) { allow.tap() } else { break }
            }
            sleep(2)

            let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back' OR label == 'Chats'")).firstMatch
            if !back.waitForExistence(timeout: 3) { print("NAVDUMP\n" + app.navigationBars.debugDescription) }
            XCTAssertTrue(back.waitForExistence(timeout: 5), "round \(round): no back button")
            back.tap()
            sleep(3)
            XCTAssertFalse(app.buttons["chat-voice-button"].exists, "round \(round): still in chat after back")
            XCTAssertEqual(app.state, .runningForeground, "round \(round): app died after back")
        }
        #endif
    }
}
