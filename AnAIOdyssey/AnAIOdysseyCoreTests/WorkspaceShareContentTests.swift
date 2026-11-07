// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

final class WorkspaceShareContentTests: XCTestCase {
    func testChatPlainTextIncludesTitleAndLabeledTurns() {
        let text = WorkspaceShareContent.chatPlainText(
            title: "Weekend plans",
            messages: [
                (role: "user", content: "What should we do?"),
                (role: "assistant", content: "Go for a hike."),
                (role: "assistant", content: "   "),
            ]
        )
        XCTAssertEqual(
            text,
            """
            Weekend plans

            You:
            What should we do?

            Assistant:
            Go for a hike.
            """
        )
    }

    func testDocumentPlainTextJoinsTitleAndBody() {
        XCTAssertEqual(
            WorkspaceShareContent.documentPlainText(title: "Notes", content: "Hello"),
            "Notes\n\nHello"
        )
        XCTAssertEqual(
            WorkspaceShareContent.documentPlainText(title: "  ", content: "Body only"),
            "Body only"
        )
    }

    func testResearchPlainTextIncludesQueryThreadAndSources() {
        let text = WorkspaceShareContent.researchPlainText(
            query: "Why is the sky blue?",
            summary: "Unused when a thread is present.",
            thread: [
                (role: "user", content: "Why is the sky blue?"),
                (role: "assistant", content: "Rayleigh scattering."),
            ],
            sources: [
                (title: "NASA", url: "https://nasa.example/sky", snippet: "Molecules scatter blue light."),
            ]
        )
        XCTAssertTrue(text.hasPrefix("Why is the sky blue?"))
        XCTAssertTrue(text.contains("You:\nWhy is the sky blue?"))
        XCTAssertTrue(text.contains("Assistant:\nRayleigh scattering."))
        XCTAssertTrue(text.contains("Sources"))
        XCTAssertTrue(text.contains("https://nasa.example/sky"))
        XCTAssertFalse(text.contains("Unused when a thread is present."))
    }

    func testResearchFallsBackToSummaryWhenThreadEmpty() {
        let text = WorkspaceShareContent.researchPlainText(
            query: "Topic",
            summary: "The answer.",
            thread: [],
            sources: []
        )
        XCTAssertEqual(text, "Topic\n\nThe answer.")
    }

    func testMessageAndImageShareTitles() {
        XCTAssertEqual(
            WorkspaceShareContent.messageShareTitle(role: "user", content: "Short"),
            "Short"
        )
        XCTAssertEqual(
            WorkspaceShareContent.messageShareTitle(role: "assistant", content: "   \n"),
            "Assistant message"
        )
        XCTAssertEqual(
            WorkspaceShareContent.imageShareTitle(caption: "Sunset", filename: "img-1.png"),
            "Sunset"
        )
        XCTAssertEqual(
            WorkspaceShareContent.imageShareTitle(caption: "  ", filename: "photo.jpeg"),
            "photo"
        )
    }
}
