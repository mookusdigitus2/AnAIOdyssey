// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// The project homepage the AI packages send (OpenRouter referer, DuckDuckGo
/// user agent) is set in one place: `PROJECT_HOMEPAGE_URL` in
/// Config/Signing.xcconfig, passed through the app's Info.plist.
final class ProjectHomepageConfigTests: XCTestCase {
    private var appRoot: URL {
        // .../OpenSource/AnAIOdyssey/AnAIOdysseyCoreTests/<file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testXcconfigDefinesANeutralPlaceholderHomepage() throws {
        let xcconfig = try read("Config/Signing.xcconfig")
        let line = try XCTUnwrap(xcconfig.split(separator: "\n")
            .first { $0.hasPrefix("PROJECT_HOMEPAGE_URL") }, "PROJECT_HOMEPAGE_URL missing")
        XCTAssertTrue(line.contains("example.com"), String(line))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("mookus" + "digitus2"))
    }

    func testInfoPlistPassesTheHomepageThrough() throws {
        let plist = try read("AnAIOdysseyApp/Info.plist")
        XCTAssertTrue(plist.contains("<key>PROJECT_HOMEPAGE_URL</key>"))
        XCTAssertTrue(plist.contains("<string>$(PROJECT_HOMEPAGE_URL)</string>"))
        let spec = try read("project.yml")
        XCTAssertTrue(spec.contains("PROJECT_HOMEPAGE_URL: $(PROJECT_HOMEPAGE_URL)"))
    }
}
