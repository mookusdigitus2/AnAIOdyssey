// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// Captures the real Settings UI for AI provider setup and spoken-reply
/// configuration. The app is launched empty (`UITEST_CONFIG_SHOTS` plus
/// `UITEST_MOCK_LLM`): no iCloud hydrate, no API keys, no sign-in, and no
/// model-list or preview network calls. OpenAI and xAI rows come from the
/// existing "Add OpenAI" / "Add xAI" buttons, which store public preset URLs
/// and an empty key.
///
/// PNGs are written to `CONFIG_SHOTS_DIR` when the runner sets
/// `TEST_RUNNER_CONFIG_SHOTS_DIR`. Attachments are always kept.
final class ConfigScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "UITEST_MOCK_LLM",
            "UITEST_CONFIG_SHOTS",
            "-anaiodyssey.setup.completed", "YES",
        ]
        app.launchEnvironment["ANAIODYSSEY_FORCE_LOCAL_STORAGE"] = "1"
    }

    func testCaptureAIAndVoiceConfigurationScreens() throws {
        #if !os(iOS)
        throw XCTSkip("Config screenshots are captured on the iOS simulator.")
        #else
        app.launch()
        dismissFirstRunIfNeeded()
        openSettings()

        openSettingsPage("aiModels", title: "AI Models")
        let addOpenAI = app.buttons["Add OpenAI"].firstMatch
        reveal(addOpenAI)
        XCTAssertTrue(addOpenAI.waitForExistence(timeout: 8), "Add OpenAI missing")
        addOpenAI.tap()
        let addXAI = app.buttons["Add xAI"].firstMatch
        reveal(addXAI)
        XCTAssertTrue(addXAI.waitForExistence(timeout: 8), "Add xAI missing")
        addXAI.tap()
        // The row button's label starts with the preset name and may include the URL.
        let openAI = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "OpenAI")).firstMatch
        let xAI = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "xAI")).firstMatch
        reveal(openAI)
        XCTAssertTrue(openAI.waitForExistence(timeout: 5), "OpenAI preset row missing")
        XCTAssertTrue(xAI.waitForExistence(timeout: 5), "xAI preset row missing")
        XCTAssertTrue(
            app.staticTexts["Enter an API key."].firstMatch.waitForExistence(timeout: 5),
            "Preset row should be keyless"
        )
        assertScreenIsSanitized()
        capture("ai-models")

        openAI.tap()
        let apiKey = app.descendants(matching: .any)["connection-api-key"].firstMatch
        XCTAssertTrue(apiKey.waitForExistence(timeout: 8), "Connection editor did not open")
        XCTAssertTrue(app.staticTexts["API Base URL"].firstMatch.waitForExistence(timeout: 5)
            || app.textFields["API Base URL"].firstMatch.waitForExistence(timeout: 2))
        assertScreenIsSanitized()
        capture("ai-connection")

        leaveConnectionEditor()
        backToSettingsList()
        openSettingsPage("voice", title: "Voice")
        let provider = app.descendants(matching: .any)["spoken-reply-provider-picker"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 8), "Voice provider picker missing")
        XCTAssertTrue(app.descendants(matching: .any)["elevenlabs-api-key"].firstMatch.waitForExistence(timeout: 5))
        assertScreenIsSanitized()
        capture("voice-settings")

        let voiceRow = app.descendants(matching: .any)["spoken-reply-voice-picker"].firstMatch
        reveal(voiceRow)
        voiceRow.tap()
        let voiceNav = app.navigationBars["Voice"].firstMatch
        XCTAssertTrue(voiceNav.waitForExistence(timeout: 8), "Voice list did not open")
        // Do not tap preview. That button calls the provider.
        assertScreenIsSanitized()
        capture("voice-list")
        #endif
    }

    private func openSettings() {
        let sidebar = app.descendants(matching: .any)["sidebar-settings"].firstMatch
        let gear = app.buttons["Settings"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while !sidebar.exists && !gear.exists && Date() < deadline {
            _ = sidebar.waitForExistence(timeout: 1)
        }
        if sidebar.exists {
            sidebar.tap()
        } else {
            XCTAssertTrue(gear.exists, "Settings missing in sidebar and toolbar")
            let sheet = element("settings-view")
            var attempts = 0
            repeat {
                gear.tap()
                attempts += 1
            } while !sheet.waitForExistence(timeout: 4) && attempts < 3
        }
        XCTAssertTrue(element("settings-view").waitForExistence(timeout: 10), "Settings did not open")
    }

    private func openSettingsPage(_ rawValue: String, title: String) {
        let link = element("settings-page-\(rawValue)")
        if link.waitForExistence(timeout: 5) {
            reveal(link)
            link.tap()
        } else {
            app.staticTexts[title].firstMatch.tap()
        }
        XCTAssertTrue(
            element("settings-page-form-\(rawValue)").waitForExistence(timeout: 10),
            "\(title) page did not open"
        )
    }

    private func leaveConnectionEditor() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            return
        }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    private func backToSettingsList() {
        if element("settings-page-aiModels").waitForExistence(timeout: 2) { return }
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.waitForExistence(timeout: 3) {
            back.tap()
        } else if app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(element("settings-page-voice").waitForExistence(timeout: 8), "Settings list did not reappear")
    }

    private func dismissFirstRunIfNeeded() {
        let notNow = app.buttons["Not now"].firstMatch
        if notNow.waitForExistence(timeout: 3) {
            notNow.tap()
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func reveal(_ element: XCUIElement) {
        var swipes = 0
        while element.exists && !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        if !element.exists {
            var searches = 0
            while !element.exists && searches < 8 {
                app.swipeUp()
                searches += 1
            }
        }
    }

    /// Fails closed before a PNG is written. Messages name the control, not its contents.
    private func assertScreenIsSanitized() {
        let bullet = CharacterSet(charactersIn: "•●*")
        for field in app.secureTextFields.allElementsBoundByIndex where field.exists {
            let raw = (field.value as? String) ?? ""
            let onlyBullets = !raw.isEmpty && raw.unicodeScalars.allSatisfy { bullet.contains($0) }
            XCTAssertFalse(onlyBullets, "Secure field \(field.identifier) is filled")
            XCTAssertFalse(raw.hasPrefix("sk-"), "Secure field \(field.identifier) has a token prefix")
            XCTAssertFalse(raw.localizedCaseInsensitiveContains("TB8778E848"))
        }
        let email = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
        for text in app.staticTexts.allElementsBoundByIndex where text.exists {
            let label = text.label
            XCTAssertFalse(label.localizedCaseInsensitiveContains("TB8778E848"))
            XCTAssertFalse(label.hasPrefix("sk-"))
            if let email, email.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
                XCTFail("Email-like text is on screen in \(text.identifier)")
            }
        }
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["CONFIG_SHOTS_DIR"], !dir.isEmpty {
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
