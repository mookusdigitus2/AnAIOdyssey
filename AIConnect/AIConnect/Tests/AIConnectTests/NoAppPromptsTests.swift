// SPDX-License-Identifier: MIT
import XCTest

/// The connectivity suite holds no app prompts, agent code or feature code.
/// Fails if any of An AI Odyssey's prompt text or agent/email types show up here.
final class NoAppPromptsTests: XCTestCase {
    static let forbidden = [
        "You are an email summarizer",
        "You are drafting an email reply",
        "email summarizer",
        "drafting an email reply",
        "MECHANICAL STYLE RULES",
        "You are an AI assistant with tool access",
        "Available tools — write a fenced code block",
        "<<<FIND>>>",
        "<<<REPLACE>>>",
        "helpful conversational assistant",
        "EmailPrompts",
        "AgentLoopService",
        "AgentToolRegistry",
        "AgentDocumentTools",
        "AgentRegistrySettings",
        "import AnAIOdysseyAI",
        "import AnAIOdysseyUI",
        "import AnAIOdysseyMail",
        "import AnAIOdysseyCore",
    ]

    func testPackageSourcesHaveNoAppPrompts() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let hits = try Self.findForbidden(in: sources)
        XCTAssertTrue(hits.isEmpty, "App prompt or agent text in AIConnect:\n" + hits.joined(separator: "\n"))
    }

    static func findForbidden(in root: URL) throws -> [String] {
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var count = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            count += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for phrase in forbidden where text.contains(phrase) {
                hits.append("\(url.lastPathComponent): \(phrase)")
            }
        }
        XCTAssertGreaterThan(count, 10, "Expected to scan the package sources at \(root.path)")
        return hits
    }
}
