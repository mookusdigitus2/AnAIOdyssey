// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

final class DeleteItemUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ANAIODYSSEY_MOCK_LLM"] = "1"
    }

    private func launchApp() {
        if app.state != .runningForeground {
            app.launch()
        }
    }

    private func tapSidebarSection(named name: String, identifier: String) {
        let byID = app.descendants(matching: .any)[identifier]
        if byID.waitForExistence(timeout: 2) {
            byID.click()
            return
        }
        app.staticTexts[name].firstMatch.click()
    }

    private func confirmDelete() {
        let byID = app.buttons["confirm-delete-button"]
        if byID.waitForExistence(timeout: 2) {
            byID.click()
            return
        }
        let sheetDelete = app.sheets.buttons["Delete"]
        if sheetDelete.waitForExistence(timeout: 2) {
            sheetDelete.click()
            return
        }
        let alertDelete = app.alerts.buttons["Delete"]
        XCTAssertTrue(alertDelete.waitForExistence(timeout: 3))
        alertDelete.click()
    }

    func testDeleteNote() throws {
        launchApp()
        tapSidebarSection(named: "Notes", identifier: "sidebar-notes")
        app.buttons["new-note-button"].click()

        let titleField = app.textFields["note-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText("Delete Me Note")

        app.buttons["delete-note-button"].click()
        confirmDelete()

        XCTAssertFalse(app.staticTexts["Delete Me Note"].waitForExistence(timeout: 2))
    }

    /// Chat delete is covered by `DeleteRepositoryTests`; UI verification is skipped
    /// because persistent CloudKit session lists make row selection unreliable in CI/dev.
    func testDeleteChat() throws {
        throw XCTSkip("Covered by DeleteRepositoryTests; chat list UI delete is flaky with large persisted session stores.")
    }

    func testDeleteDocument() throws {
        launchApp()
        tapSidebarSection(named: "Documents", identifier: "sidebar-documents")
        app.buttons["new-document-button"].click()

        let titleField = app.textFields["document-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeText("Delete Me Doc")

        app.buttons["delete-document-button"].click()
        confirmDelete()

        XCTAssertFalse(app.staticTexts["Delete Me Doc"].waitForExistence(timeout: 5))
    }
}
