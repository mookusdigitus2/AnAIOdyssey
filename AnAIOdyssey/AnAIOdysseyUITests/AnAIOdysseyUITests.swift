// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

final class AnAIOdysseyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        if name.contains("FakeInbox") {
            app.launchArguments += ["UITEST_FAKE_MAIL"]
            app.launchEnvironment["ANAIODYSSEY_FAKE_MAIL"] = "1"
        }
        app.launch()
    }

    private func activate(_ element: XCUIElement) {
        let target = element.firstMatch
        #if os(macOS)
        target.click()
        #else
        target.tap()
        #endif
    }

    private func tapSidebarSection(named name: String, identifier: String) {
        let byID = app.descendants(matching: .any)[identifier]
        if byID.waitForExistence(timeout: 2) {
            activate(byID)
            return
        }
        activate(app.staticTexts[name].firstMatch)
    }

    /// Email lives in the top tab bar on Mac/iPad and in Library on iPhone.
    private func openEmailWorkspace() {
        let emailTab = app.descendants(matching: .any)["sidebar-email"]
        if emailTab.waitForExistence(timeout: 4) {
            activate(emailTab)
            return
        }
        let libraryTab = app.tabBars.buttons["Library"]
        if libraryTab.waitForExistence(timeout: 3) {
            activate(libraryTab)
        }
        let tile = app.descendants(matching: .any)["library-email"]
        if tile.waitForExistence(timeout: 4) {
            activate(tile)
            return
        }
        activate(app.staticTexts["Email"].firstMatch)
    }

    #if os(iOS)
    /// iPhone Duo inner display (an iPad simulator with `-DuoLayout` stands in, since there is
    /// no Duo simulator before Xcode 27.1): every tab is on the narrow rail at the right edge,
    /// top to bottom in the usual order, with the selected one marked. No sidebar list.
    func testDuoInnerDisplayPutsEveryTabOnTheRightRail() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad simulator stands in for the open Duo")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.terminate()
        app.launchArguments += ["-DuoLayout"]
        app.launch()
        let chats = app.buttons["rail-chats"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 10), "tab rail shows on the open Duo")
        let window = app.windows.firstMatch.frame
        var lastY = -CGFloat.infinity
        for id in ["rail-chats", "rail-documents", "rail-notes", "rail-memory"] {
            let e = app.buttons[id].firstMatch
            XCTAssertTrue(e.waitForExistence(timeout: 5), id)
            XCTAssertGreaterThan(e.frame.minX, window.maxX - 120, "\(id) on the right edge: \(e.frame) in \(window)")
            XCTAssertGreaterThan(e.frame.midY, lastY, "\(id) below the tab before it")
            XCTAssertGreaterThanOrEqual(e.frame.width, 44)
            XCTAssertGreaterThanOrEqual(e.frame.height, 44)
            XCTAssertFalse(e.label.isEmpty, "\(id) VoiceOver label")
            lastY = e.frame.midY
        }
        XCTAssertTrue(chats.isSelected, "the selected tab is marked")
        XCTAssertFalse(app.descendants(matching: .any)["section-sidebar"].exists, "no sidebar list on the open Duo")
        duoShot("odyssey-duo-rail")
        app.buttons["rail-documents"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Document Selected"].waitForExistence(timeout: 5),
                      "Documents opens from the rail")
        XCTAssertTrue(app.buttons["rail-documents"].firstMatch.isSelected)
    }

    /// iPad keeps its sidebar on the left.
    func testIPadKeepsSectionSidebarOnTheLeft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "runs on an iPad simulator")
        XCUIDevice.shared.orientation = .landscapeLeft
        let chats = app.descendants(matching: .any)["sidebar-chats"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(chats.frame.maxX, window.midX, "iPad sidebar stays on the left: \(chats.frame) in \(window)")
        duoShot("odyssey-ipad-unchanged")
    }

    /// Review screenshots: also written to `DUO_SHOTS_DIR` when the runner sets it
    /// (TEST_RUNNER_DUO_SHOTS_DIR=<dir>).
    private func duoShot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["DUO_SHOTS_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
    #endif

    func testMacAppLaunches() throws {
        XCTAssertTrue(app.staticTexts["An AI Odyssey"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Chats"].exists || app.otherElements["root-view"].exists)
    }

    func testIPadAppLaunches() throws {
        XCTAssertTrue(app.staticTexts["An AI Odyssey"].waitForExistence(timeout: 10))
    }

    func testSidebarShowsCoreSections() throws {
        XCTAssertTrue(app.staticTexts["Chats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Documents"].exists)
        XCTAssertTrue(app.staticTexts["Notes"].exists)
        XCTAssertTrue(app.staticTexts["Settings"].exists)
    }

    func testEmailSectionIsAvailable() throws {
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-email"].waitForExistence(timeout: 8)
            || app.staticTexts["Email"].waitForExistence(timeout: 2))
    }

    func testSectionSelectionChangesDetail() throws {
        tapSidebarSection(named: "Documents", identifier: "sidebar-documents")
        XCTAssertTrue(app.buttons["new-document-button"].waitForExistence(timeout: 5))

        tapSidebarSection(named: "Notes", identifier: "sidebar-notes")
        XCTAssertTrue(app.buttons["new-note-button"].waitForExistence(timeout: 5))

        tapSidebarSection(named: "Chats", identifier: "sidebar-chats")
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 5))
    }

    func testDocumentsSectionReady() throws {
        tapSidebarSection(named: "Documents", identifier: "sidebar-documents")
        XCTAssertTrue(app.buttons["new-document-button"].waitForExistence(timeout: 5))
    }

    func testCreateNote() throws {
        tapSidebarSection(named: "Notes", identifier: "sidebar-notes")
        app.buttons["new-note-button"].click()
        XCTAssertTrue(app.textFields["note-title-field"].waitForExistence(timeout: 5))
    }

    func testCreateChatAndSend() throws {
        tapSidebarSection(named: "Chats", identifier: "sidebar-chats")
        app.buttons["new-chat-button"].click()

        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("Hello AnAIOdyssey")
        app.buttons["chat-send-button"].click()
        XCTAssertTrue(app.staticTexts["Hello AnAIOdyssey"].waitForExistence(timeout: 5))
    }

    func testEmailTabShowsConnectionManagerFakeInbox() throws {
        openEmailWorkspace()

        let connectGmail = app.descendants(matching: .any)["connect-gmail-button"]
        let messageList = app.descendants(matching: .any)["email-message-list"]
        let firstRow = app.descendants(matching: .any)["email-row-Quarterly planning"].firstMatch
        let emailView = app.descendants(matching: .any)["email-view"]
        let browser = app.descendants(matching: .any)["email-browser"]

        let inboxAppeared = firstRow.waitForExistence(timeout: 10)
            || messageList.waitForExistence(timeout: 2)
            || browser.waitForExistence(timeout: 2)
            || emailView.waitForExistence(timeout: 2)
        XCTAssertFalse(
            connectGmail.exists,
            "Fake inbox was not installed; Email showed Connect Gmail instead of preview messages."
        )
        XCTAssertTrue(inboxAppeared, "Expected the Email workspace after tapping Email.")

        for subject in ["Quarterly planning", "Lunch tomorrow", "Ship checklist"] {
            let row = app.descendants(matching: .any)["email-row-\(subject)"].firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 8),
                "Expected Email tab to show fake inbox message '\(subject)'"
            )
        }

        if app.buttons["email-message-1"].waitForExistence(timeout: 2) {
            activate(app.buttons["email-message-1"])
        } else {
            activate(firstRow)
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["email-body-text"].waitForExistence(timeout: 8),
            "Selecting a fake inbox row should open the message body"
        )
    }

    func testSummarizeActionUI() throws {
        #if os(macOS)
        throw XCTSkip("Summarize pipeline covered by AnAIOdysseyMailTests/EmailAITests; verify manually in Email → Summarize.")
        #endif
    }
}
