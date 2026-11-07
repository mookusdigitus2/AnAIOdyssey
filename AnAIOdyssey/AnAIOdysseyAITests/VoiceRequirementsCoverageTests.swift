// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest

/// REQ-14: every requirement in AnAIOdyssey/docs/VOICE_MODE_REQUIREMENTS.md
/// has at least one automated test in this target tagged with its ID
/// (`REQ-07` in a `///` line right above the test, or `REQ07` in its name).
/// The same check runs as Scripts/check_voice_requirements_coverage.sh.
final class VoiceRequirementsCoverageTests: XCTestCase {
    private var testsDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    private var docURL: URL {
        testsDirectory.deletingLastPathComponent().appendingPathComponent("docs/VOICE_MODE_REQUIREMENTS.md")
    }

    static func requirementIDs(inDoc text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"^\d+\. \*\*(REQ-\d{2})\b"#, options: .anchorsMatchLines)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// IDs tagged on test functions in one source file.
    static func taggedIDs(inTestSource text: String) -> Set<String> {
        let tag = try! NSRegularExpression(pattern: #"REQ-?(\d{2})"#)
        func ids(_ line: String) -> [String] {
            tag.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
                Range($0.range(at: 1), in: line).map { "REQ-" + line[$0] }
            }
        }
        var found = Set<String>()
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func test") else { continue }
            let name = trimmed.dropFirst("func ".count).prefix { $0 != "(" }
            found.formUnion(ids(String(name)))
            var above = index - 1
            while above >= 0, lines[above].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                found.formUnion(ids(lines[above]))
                above -= 1
            }
        }
        return found
    }

    func testREQ14_EveryRequirementHasATaggedTest() throws {
        guard let doc = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw XCTSkip("requirements doc not available at \(docURL.path)")
        }
        let required = Self.requirementIDs(inDoc: doc)
        XCTAssertGreaterThanOrEqual(required.count, 15, "the doc's requirement IDs were not found")
        XCTAssertEqual(required, (1...required.count).map { String(format: "REQ-%02d", $0) }, "IDs are REQ-01… in order")

        var tagged = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(atPath: testsDirectory.path).filter { $0.hasSuffix(".swift") }
        for file in files {
            let text = try String(contentsOf: testsDirectory.appendingPathComponent(file), encoding: .utf8)
            tagged.formUnion(Self.taggedIDs(inTestSource: text))
        }
        let missing = required.filter { !tagged.contains($0) }
        XCTAssertEqual(missing, [], "requirements with no automated test")
    }

    /// REQ-14: the parser itself.
    func testREQ14_CoverageParser() {
        let doc = "## A\n1. **REQ-01 One:** x\n2. **REQ-02 Two:** y\n- not 3. **REQ-03"
        XCTAssertEqual(Self.requirementIDs(inDoc: doc), ["REQ-01", "REQ-02"])
        let source = """
            /// Something.
            /// REQ-02, REQ-05
            func testThing() {}
            /// REQ-09 not attached
            let x = 1
            func testREQ07_Named() {}
            func helper() { // REQ-08
            }
            """
        XCTAssertEqual(Self.taggedIDs(inTestSource: source), ["REQ-02", "REQ-05", "REQ-07"])
    }
}
