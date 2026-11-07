// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Chat replies belong to the app, not the chat screen: leaving the chat while
/// it is answering must not lose the reply.
final class BackgroundRunUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !os(iOS)
        throw XCTSkip("iPhone navigation")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        app.launch()
    }

    func testLeavingChatWhileAnsweringKeepsTheReply() throws {
        let chats = app.descendants(matching: .any)["sidebar-chats"]
        if chats.waitForExistence(timeout: 3) { chats.tap() }
        else if app.tabBars.buttons["Chats"].exists { app.tabBars.buttons["Chats"].tap() }

        let newChat = app.buttons["new-chat-button"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8))
        newChat.tap()

        let composer = app.textFields["chat-composer"].exists
            ? app.textFields["chat-composer"] : app.textViews["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Background reply check")
        app.buttons["chat-send-button"].tap()

        // Leave right away.
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Chats' OR label == 'Back'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()

        // Switch tabs and come back, then reopen the chat.
        if app.tabBars.buttons["Research"].exists {
            app.tabBars.buttons["Research"].tap()
            app.tabBars.buttons["Chats"].tap()
        }
        let row = app.descendants(matching: .any)["chat-session-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // The mock model answers "Mock MLX reply to: …" once the run finishes.
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Mock MLX reply to'")).firstMatch
        let found = reply.waitForExistence(timeout: 15)
        XCTAssertTrue(found, "Reply was lost when leaving the chat")
        XCTAssertTrue(app.buttons["chat-send-button"].waitForExistence(timeout: 5), "Chat still looks busy after the reply finished")
    }
}
