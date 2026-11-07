// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ThinkingSectionPolicyTests: XCTestCase {
    func testDurationLabelSingularPluralAndMoment() {
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 0), "Thought for a moment")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 0.4), "Thought for a moment")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 0.99), "Thought for a moment")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 1), "Thought for 1 second")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 1.4), "Thought for 1 second")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 1.5), "Thought for 2 seconds")
        XCTAssertEqual(ThinkingSectionPolicy.durationLabel(seconds: 12), "Thought for 12 seconds")
    }

    func testDurationLabelFromDates() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ThinkingSectionPolicy.durationLabel(from: start, to: start.addingTimeInterval(0.2)),
            "Thought for a moment"
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.durationLabel(from: start, to: start.addingTimeInterval(1)),
            "Thought for 1 second"
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.durationLabel(from: start, to: start.addingTimeInterval(3.2)),
            "Thought for 3 seconds"
        )
    }

    func testPresentationOpensWhileStreamingThenCollapses() {
        XCTAssertEqual(
            ThinkingSectionPolicy.presentation(
                hasReasoning: false,
                hasContent: false,
                isStreaming: true,
                userExpanded: false,
                durationSeconds: nil
            ),
            .hidden
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.presentation(
                hasReasoning: true,
                hasContent: false,
                isStreaming: true,
                userExpanded: false,
                durationSeconds: nil
            ),
            .streaming
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.presentation(
                hasReasoning: true,
                hasContent: true,
                isStreaming: true,
                userExpanded: false,
                durationSeconds: 3
            ),
            .collapsed(label: "Thought for 3 seconds")
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.presentation(
                hasReasoning: true,
                hasContent: true,
                isStreaming: true,
                userExpanded: true,
                durationSeconds: 3
            ),
            .expanded(label: "Thought for 3 seconds")
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.presentation(
                hasReasoning: true,
                hasContent: true,
                isStreaming: false,
                userExpanded: false,
                durationSeconds: 1
            ),
            .collapsed(label: "Thought for 1 second")
        )
        XCTAssertEqual(
            ThinkingSectionPolicy.persistedTitle(durationSeconds: nil),
            "Thinking"
        )
        XCTAssertTrue(ThinkingSectionPolicy.shouldForceCollapse(hasContent: true, userExpanded: false))
        XCTAssertFalse(ThinkingSectionPolicy.shouldForceCollapse(hasContent: true, userExpanded: true))
        XCTAssertFalse(ThinkingSectionPolicy.shouldForceCollapse(hasContent: false, userExpanded: false))
    }

    func testReasoningMetadataRoundTripPreservesOtherKeys() {
        let existing = #"{"webSearchUsed":true}"#
        let merged = ThinkingSectionPolicy.mergeReasoning(
            existing: existing,
            reasoning: " consider the options ",
            durationSeconds: 4
        )
        XCTAssertEqual(ThinkingSectionPolicy.reasoning(from: merged), "consider the options")
        XCTAssertEqual(ThinkingSectionPolicy.thoughtDurationSeconds(from: merged), 4)
        XCTAssertTrue(merged?.contains("webSearchUsed") == true)

        let cleared = ThinkingSectionPolicy.mergeReasoning(
            existing: merged,
            reasoning: "  ",
            durationSeconds: 4
        )
        XCTAssertNil(ThinkingSectionPolicy.reasoning(from: cleared))
        XCTAssertNil(ThinkingSectionPolicy.thoughtDurationSeconds(from: cleared))
    }
}
