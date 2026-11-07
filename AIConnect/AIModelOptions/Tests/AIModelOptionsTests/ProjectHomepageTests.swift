// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// The project homepage sent in attribution headers and user agents is one
/// host-configurable value with a neutral default.
final class ProjectHomepageTests: XCTestCase {
    override func tearDown() {
        AIProjectHomepage.override = nil
        super.tearDown()
    }

    func testDefaultIsANeutralPlaceholder() {
        XCTAssertEqual(AIProjectHomepage.placeholderURL, "https://example.com")
        XCTAssertEqual(AIProjectHomepage.resolve(infoValue: nil), AIProjectHomepage.placeholderURL)
    }

    func testInfoPlistValueIsUsedWhenSet() {
        XCTAssertEqual(AIProjectHomepage.resolve(infoValue: "https://my.app/home"), "https://my.app/home")
    }

    func testBlankOrUnexpandedInfoPlistValueFallsBackToPlaceholder() {
        XCTAssertEqual(AIProjectHomepage.resolve(infoValue: "  "), AIProjectHomepage.placeholderURL)
        XCTAssertEqual(AIProjectHomepage.resolve(infoValue: "$(PROJECT_HOMEPAGE_URL)"), AIProjectHomepage.placeholderURL)
    }

    func testHostOverrideWins() {
        AIProjectHomepage.override = "https://host.example/app"
        XCTAssertEqual(AIProjectHomepage.url, "https://host.example/app")
        XCTAssertEqual(AIProjectHomepage.resolve(infoValue: "https://my.app/home"), "https://host.example/app")
    }

    func testDuckDuckGoUserAgentCarriesTheHomepage() {
        AIProjectHomepage.override = "https://host.example/app"
        XCTAssertEqual(DuckDuckGoSearchCodec.userAgent,
                       "AnAIOdyssey/1.0 (+https://host.example/app; Instant Answer client)")
    }
}

/// No file under OpenSource/ may point at the private monorepo or its org.
final class NoPrivateRepoReferenceTests: XCTestCase {
    func testNoSourceUnderOpenSourceMentionsThePrivateOrg() throws {
        // Built from parts so this file does not match itself.
        let needles = ["mookus" + "digitus2", "github.com/" + "mookus"]
        // .../OpenSource/AIConnect/AIModelOptions/Tests/AIModelOptionsTests/<file>
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        XCTAssertEqual(root.lastPathComponent, "OpenSource")

        let textExtensions: Set<String> = [
            "swift", "md", "yml", "yaml", "plist", "xcconfig", "json", "resolved", "sh",
            "py", "txt", "entitlements", "pbxproj", "xcscheme", "example", "strings", "html",
        ]
        let skipDirs: Set<String> = [".build", "DerivedData", ".swiftpm", "xcuserdata"]
        var hits: [String] = []
        var scanned = 0
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            if skipDirs.contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard textExtensions.contains(ext) || url.lastPathComponent.hasPrefix("LICENSE")
                    || url.lastPathComponent == ".gitignore" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if needles.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                hits.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        XCTAssertGreaterThan(scanned, 100, "scan found too few files; wrong root?")
        XCTAssertEqual(hits, [], "private repo references: \(hits)")
    }
}
