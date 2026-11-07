// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// iPhone chat list: Select → Select All (or tapping rows) must enable "Delete N Chats".
/// Build 17 shipped a bug where Delete stayed disabled after selecting.
final class ChatSelectDeleteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !os(iOS)
        throw XCTSkip("iPhone Select mode only")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        app.launch()
    }

    private func openChats() {
        let chats = app.descendants(matching: .any)["sidebar-chats"]
        if chats.waitForExistence(timeout: 3) { chats.tap() }
        else if app.tabBars.buttons["Chats"].exists { app.tabBars.buttons["Chats"].tap() }
    }

    private func makeChatsAndReturnToList(_ count: Int) {
        openChats()
        for _ in 0..<count {
            let newChat = app.buttons["new-chat-button"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 8))
            newChat.tap()
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Chats' OR label == 'Back'")).firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
        }
        XCTAssertTrue(app.buttons["chat-select-button"].waitForExistence(timeout: 5))
    }

    private var deleteButton: XCUIElement { app.buttons["delete-chat-button"] }

    func testSelectAllEnablesDelete() throws {
        makeChatsAndReturnToList(2)
        app.buttons["chat-select-button"].tap()
        let selectAll = app.buttons["chat-select-all-button"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 1), "Select All missing in Select mode")
        selectAll.tap()
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: deleteButton)
        waitForExpectations(timeout: 3)
        XCTAssertNotEqual(deleteButton.label, "Delete 0 Chats")
        deleteButton.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3) || app.sheets.firstMatch.waitForExistence(timeout: 1),
                      "delete confirmation did not appear")
    }

    func testTappingRowEnablesDelete() throws {
        makeChatsAndReturnToList(1)
        app.buttons["chat-select-button"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "chat-session-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: deleteButton)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(deleteButton.isHittable, "Delete button not hittable")
        deleteButton.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3) || app.sheets.firstMatch.waitForExistence(timeout: 1),
                      "delete confirmation did not appear")
    }
}
