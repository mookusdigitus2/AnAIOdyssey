// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

final class StreamingTextBatcherTests: XCTestCase {
    func testEmitsOnlyAtSentenceBoundaries() {
        var batcher = StreamingTextBatcher()

        // Token-sized growth below a boundary never updates the screen.
        XCTAssertNil(batcher.displayText(for: "The"))
        XCTAssertNil(batcher.displayText(for: "The quick"))
        XCTAssertNil(batcher.displayText(for: "The quick brown fox."))

        // Punctuation followed by whitespace completes the sentence.
        XCTAssertEqual(
            batcher.displayText(for: "The quick brown fox. It"),
            "The quick brown fox. "
        )

        // No new boundary — no update.
        XCTAssertNil(batcher.displayText(for: "The quick brown fox. It jumps"))

        // finish always flushes the full text.
        XCTAssertEqual(
            batcher.finish("The quick brown fox. It jumps over"),
            "The quick brown fox. It jumps over"
        )
    }

    func testEmitsOnLineBreaks() {
        var batcher = StreamingTextBatcher()
        XCTAssertNil(batcher.displayText(for: "Line one"))
        XCTAssertEqual(batcher.displayText(for: "Line one\nLine"), "Line one\n")
        XCTAssertEqual(batcher.displayText(for: "Line one\nLine two\r\nMore"), "Line one\nLine two\r\n")
    }

    func testShortTextIsRenderedOnceAtFinish() {
        var batcher = StreamingTextBatcher()
        XCTAssertNil(batcher.displayText(for: "Hi"))
        XCTAssertEqual(batcher.finish("Hi"), "Hi")
    }

    func testDoesNotBreakOnDecimalsOrURLs() {
        var batcher = StreamingTextBatcher()
        XCTAssertNil(batcher.displayText(for: "pi is 3.14159 and"))
        XCTAssertNil(batcher.displayText(for: "see https://example.com/a.b?c=d and"))
    }

    func testRewrittenShorterStreamIsShownImmediately() {
        var batcher = StreamingTextBatcher()
        _ = batcher.displayText(for: "First round sentence. Trailing")
        XCTAssertEqual(batcher.displayText(for: "New round"), "New round")
    }

    func testMarkDisplayedSkipsAlreadyShownText() {
        var batcher = StreamingTextBatcher()
        batcher.markDisplayed("Shown already. ")
        XCTAssertNil(batcher.displayText(for: "Shown already. More"))
        XCTAssertEqual(
            batcher.displayText(for: "Shown already. More text arrives. Then"),
            "Shown already. More text arrives. "
        )
    }

    func testUpdateCountIsFarBelowChunkCount() {
        var batcher = StreamingTextBatcher()
        let text = Array(repeating: "This is a sentence about batching. ", count: 20).joined()
        var cumulative = ""
        var updates = 0
        // Simulate 4-character streaming chunks.
        for chunk in stride(from: 0, to: text.count, by: 4).map({ offset -> String in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(4, text.count - offset))
            return String(text[start..<end])
        }) {
            cumulative += chunk
            if batcher.displayText(for: cumulative) != nil {
                updates += 1
            }
        }
        _ = batcher.finish(cumulative)
        // 20 sentences → at most ~20 screen updates instead of ~175 chunk updates.
        XCTAssertLessThanOrEqual(updates, 20)
        XCTAssertGreaterThan(updates, 0)
    }
}
