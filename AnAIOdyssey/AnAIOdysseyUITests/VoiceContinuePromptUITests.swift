// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// The barge-in prompt's layout: "Would you like me to continue?" with Yes
/// and No in the chat. Rendered via UITEST_VOICE_CONTINUE_PROMPT (no mic on
/// the simulator); the behavior is covered by VoiceContinuePromptControllerTests.
final class VoiceContinuePromptUITests: XCTestCase {
    func testContinuePromptShowsQuestionWithYesAndNo() throws {
        #if os(iOS)
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM", "UITEST_VOICE_CONTINUE_PROMPT"]
        app.launch()
        let chats = app.descendants(matching: .any).matching(identifier: "sidebar-chats").firstMatch
        if chats.waitForExistence(timeout: 3) { chats.tap() } else if app.tabBars.buttons["Chats"].exists { app.tabBars.buttons["Chats"].tap() }
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 8))
        app.buttons["new-chat-button"].tap()

        let prompt = app.descendants(matching: .any).matching(identifier: "chat-voice-continue-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertTrue(prompt.label.contains("Would you like me to continue?"), prompt.label)
        XCTAssertTrue(app.buttons["chat-voice-continue-yes"].exists)
        XCTAssertTrue(app.buttons["chat-voice-continue-no"].exists)
        XCTAssertEqual(app.buttons["chat-voice-continue-yes"].label, "Yes")
        XCTAssertEqual(app.buttons["chat-voice-continue-no"].label, "No")

        let screenshot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["VOICE_SHOTS_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("continue-prompt.png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "continue-prompt"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }
}
