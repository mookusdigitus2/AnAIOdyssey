// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI
@testable import AnAIOdysseyMail

@MainActor
final class EmailAITests: XCTestCase {
    func testSummarizeEmailMockLLM() async throws {
        let llm = MockLLMService()
        try await llm.loadSelectedModel()

        let service = EmailAIService(llmService: llm)
        let summary = try await service.summarize(
            EmailAIInput(
                sender: "sender@example.com",
                subject: "Fixture Test Email",
                body: "Hello from the fixture email body."
            )
        )

        XCTAssertTrue(summary.contains("Mock summary"))
    }

    func testReplyDraftIncludesThreadContext() async throws {
        let llm = MockLLMService()
        try await llm.loadSelectedModel()

        let prompt = EmailPrompts.replyUserPrompt(
            recipient: "sender@example.com",
            subject: "Weekly Digest",
            originalBody: "Plain digest summary."
        )
        XCTAssertTrue(prompt.contains("sender@example.com"))
        XCTAssertTrue(prompt.contains("Weekly Digest"))
        XCTAssertTrue(prompt.contains("Plain digest summary."))

        let service = EmailAIService(llmService: llm)
        let reply = try await service.draftReply(
            EmailAIInput(
                sender: "Service Alerts",
                subject: "Weekly Digest",
                body: "Plain digest summary.",
                recipient: "sender@example.com"
            )
        )

        XCTAssertFalse(reply.isEmpty)
        XCTAssertTrue(reply.contains("Weekly Digest") || reply.contains("Thanks"))
    }

    func testEmailAIServiceHandlesEmptyBody() async {
        let llm = MockLLMService()
        try? await llm.loadSelectedModel()
        let service = EmailAIService(llmService: llm)

        do {
            _ = try await service.summarize(
                EmailAIInput(sender: "a@b.com", subject: "Hi", body: "   ")
            )
            XCTFail("Expected empty body error")
        } catch {
            XCTAssertEqual(error as? EmailAIError, .emptyBody)
        }
    }

    func testEmailResponseParserExtractsSummaryMarkers() {
        let parsed = EmailResponseParser.extractFencedOutput(from: """
        Some reasoning here.
        <<<SUMMARY>>>
        - First point
        - Second point
        <<<END>>>
        """)
        XCTAssertEqual(parsed, "- First point\n- Second point")
    }
}
