// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Walks the Continue with ChatGPT screens and keeps screenshots in the
/// result bundle. iPhone/iPad only: macOS hands sign-in to the system browser.
final class ChatGPTSignInUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if os(macOS)
        throw XCTSkip("macOS opens the system browser; covered by unit tests.")
        #else
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["UITEST_MOCK_LLM"]
        #endif
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // Optional copy for review: TEST_RUNNER_SIWC_SHOTS_DIR=/path xcodebuild test …
        if let dir = ProcessInfo.processInfo.environment["SIWC_SHOTS_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            )
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openAIModelsSettings() {
        let label = app.staticTexts["Settings"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "Settings missing in sidebar")
        label.tap()
        let page = element("settings-page-aiModels")
        if page.waitForExistence(timeout: 5) {
            page.tap()
        } else {
            app.staticTexts["AI Models"].firstMatch.tap()
        }
    }

    /// Settings ▸ AI Models with no account shows the plan offer; tapping it
    /// opens the OpenAI sign-in sheet while the 127.0.0.1 listener waits. (On
    /// devices without Apple Intelligence the same offer is the first-run sheet.)
    func testSettingsOfferAndSignInSheet() throws {
        app.launchArguments += ["-anaiodyssey.setup.completed", "YES"]
        app.launch()
        openAIModelsSettings()
        let button = element("continue-with-chatgpt")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Continue with ChatGPT missing in Settings")
        shot("01-settings-ai-models-offer")
        button.tap()

        // System prompt: "“An AI Odyssey” Wants to Use “openai.com” to Sign In".
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Continue"]
        if allow.waitForExistence(timeout: 10) {
            shot("02-system-sign-in-prompt")
            allow.tap()
        }
        sleep(10)
        shot("03-openai-sign-in-sheet")
        // Expand OpenAI's diagnostics if the page shows them (web content lives
        // in SafariViewService, not the app).
        for host in [app!, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            let diagnostics = host.staticTexts["View diagnostics"].firstMatch
            if diagnostics.waitForExistence(timeout: 2) {
                diagnostics.tap()
                sleep(2)
                shot("03b-openai-diagnostics")
                break
            }
        }

        // A host script sends a forged callback to the app's 127.0.0.1
        // listener; the app must reject it on state and close the sheet.
        let rejected = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'state'")
        ).firstMatch
        if rejected.waitForExistence(timeout: 90) {
            shot("04-forged-callback-rejected")
        } else {
            shot("04-no-callback")
        }
    }

    /// Signed in (fake DEBUG account): one-time notice, then the in-use label.
    func testSignedInPlanUI() throws {
        app.launchArguments += ["-anaiodyssey.setup.completed", "YES", "UITEST_CHATGPT_PLAN"]
        app.launch()
        openAIModelsSettings()
        let gotIt = app.buttons["Got it"].firstMatch
        XCTAssertTrue(gotIt.waitForExistence(timeout: 10), "One-time plan notice missing")
        shot("05-plan-notice")
        gotIt.tap()
        let label = element("chatgpt-plan-in-use")
        XCTAssertTrue(label.waitForExistence(timeout: 8), "Using ChatGPT plan label missing")
        shot("06-settings-using-chatgpt-plan")
    }
}
