// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Settings > About > Acknowledgements lists every bundled package with its
/// license, then the app's own AGPL notice and app store permission.
final class AcknowledgementsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM", "-anaiodyssey.setup.completed", "YES"]
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testAcknowledgementsRowOpensTheLicenseList() throws {
        app.launch()
        // iPad and Mac show Settings in the sidebar; iPhone shows a gear
        // button (labelled "Settings") in each tab's toolbar.
        let sidebarSettings = app.staticTexts["Settings"].firstMatch
        let gearSettings = app.buttons["Settings"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while !sidebarSettings.exists && !gearSettings.exists && Date() < deadline {
            _ = sidebarSettings.waitForExistence(timeout: 1)
        }
        if sidebarSettings.exists {
            sidebarSettings.tap()
        } else {
            XCTAssertTrue(gearSettings.exists, "Settings missing in sidebar and toolbar")
            // The first tap can land while a launch-time prompt is still up,
            // so retry until the Settings sheet is on screen.
            let sheet = element("settings-view")
            var attempts = 0
            repeat {
                gearSettings.tap()
                attempts += 1
            } while !sheet.waitForExistence(timeout: 4) && attempts < 3
            XCTAssertTrue(sheet.exists, "Settings sheet did not open")
        }
        let about = element("settings-page-about")
        if about.waitForExistence(timeout: 5) {
            var swipes = 0
            while !about.isHittable && swipes < 6 {
                app.swipeUp()
                swipes += 1
            }
            about.tap()
        } else {
            app.staticTexts["About"].firstMatch.tap()
        }
        let row = element("settings-acknowledgements")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Acknowledgements row missing")
        var rowSwipes = 0
        while !row.isHittable && rowSwipes < 6 {
            app.swipeUp()
            rowSwipes += 1
        }
        row.tap()

        XCTAssertTrue(element("acknowledgements-list").waitForExistence(timeout: 10))
        XCTAssertTrue(element("acknowledgement-aiconnect").waitForExistence(timeout: 5))
        XCTAssertTrue(element("acknowledgement-odysseus").waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        // The list is lazy: on a phone, third-party packages are built only
        // once they scroll into view.
        let mlx = element("acknowledgement-mlx-swift")
        var listSwipes = 0
        while !mlx.exists && listSwipes < 20 {
            element("acknowledgements-list").swipeUp()
            listSwipes += 1
        }
        XCTAssertTrue(mlx.exists, "mlx-swift notice missing from the list")
        if let dir = ProcessInfo.processInfo.environment["ACK_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("acknowledgements.png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "acknowledgements"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
