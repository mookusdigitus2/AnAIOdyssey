// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class StreamingSpeechChunkerTests: XCTestCase {
    func testEmitsCompletedSentencesIncrementally() {
        var chunker = StreamingSpeechChunker()

        XCTAssertEqual(chunker.consume(cumulative: "Hello"), [])
        XCTAssertEqual(
            chunker.consume(cumulative: "Hello there. How"),
            ["Hello there."]
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "Hello there. How are you? Fine"),
            ["How are you?"]
        )
        XCTAssertEqual(
            chunker.finish(cumulative: "Hello there. How are you? Fine day"),
            ["Fine day"]
        )
    }

    func testFirstChunkWaitsForAFullSentence() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "I'll look that up, then summarize the rest"),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "I'll look that up, then summarize the rest."),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "I'll look that up, then summarize the rest. Next"),
            ["I'll look that up, then summarize the rest."]
        )
    }

    func testDoesNotCutAtEightWordsOrADash() {
        var chunker = StreamingSpeechChunker()
        let eight = "I'll research Scout's latest vehicles for you now "
        XCTAssertEqual(chunker.consume(cumulative: eight), [])
        XCTAssertEqual(
            chunker.consume(cumulative: eight + "and then compare them — still going"),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: eight + "and then compare them. Next"),
            ["I'll research Scout's latest vehicles for you now and then compare them."]
        )
    }

    func testSkipsAbbreviationsAndInitials() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "Dr. Smith met the U.S. team at 9. Then we left"),
            ["Dr. Smith met the U.S. team at 9."]
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "See Mr. Jones and Ms. Lee. Done"),
            ["See Mr. Jones and Ms. Lee."]
        )
    }

    func testDoesNotSplitDecimalsOrURLs() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "pi is 3.14159 and more"),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "see https://example.com/a.b?c=d please"),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "pi is 3.14159 today. Next"),
            ["pi is 3.14159 today."]
        )
    }

    func testEllipsisDoesNotSplitAContinuation() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(chunker.consume(cumulative: "Wait..."), [])
        XCTAssertEqual(
            chunker.consume(cumulative: "Wait... then we kept going without a period"),
            []
        )
        XCTAssertEqual(
            chunker.consume(cumulative: "Wait... then we kept going. Next"),
            ["Wait... then we kept going."]
        )
    }

    func testEllipsisThenCapitalStartsANewSentence() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "Hold on... Then we left the room"),
            ["Hold on..."]
        )
    }

    func testStreamTextSnapshotsDoNotRespeakPrefixes() {
        var accumulator = StreamTextAccumulator()
        var chunker = StreamingSpeechChunker()

        _ = accumulator.apply(.snapshot("Hello"))
        XCTAssertEqual(chunker.consume(cumulative: accumulator.text), [])

        _ = accumulator.apply(.snapshot("Hello there. "))
        XCTAssertEqual(chunker.consume(cumulative: accumulator.text), ["Hello there."])

        _ = accumulator.apply(.snapshot("Hello there. How are you?"))
        XCTAssertEqual(chunker.finish(cumulative: accumulator.text), ["How are you?"])
        XCTAssertEqual(chunker.consume(cumulative: accumulator.text), [])
    }

    func testDoesNotRespeakWhenStreamIsRewritten() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "Let me check that.\n"),
            ["Let me check that."]
        )
        XCTAssertEqual(chunker.consume(cumulative: "Let me check that."), [])
        XCTAssertEqual(chunker.finish(cumulative: "Let me check that."), [])
    }

    func testMarkSpokenSkipsHandedOverText() {
        var chunker = StreamingSpeechChunker()
        chunker.markSpoken(cumulative: "One. Two. ")
        XCTAssertEqual(chunker.consume(cumulative: "One. Two. Three. Fo"), ["Three."])
        XCTAssertEqual(chunker.finish(cumulative: "One. Two. Three. Four"), ["Four"])
    }

    func testStripsLightMarkdownForSpeech() {
        XCTAssertEqual(
            StreamingSpeechChunker.speakableText("**Bold** and [link](https://example.com)"),
            "Bold and link"
        )
        XCTAssertNil(StreamingSpeechChunker.speakableText("   "))
    }

    func testSafetyFlushCutsLongSentenceAtLastClause() {
        var chunker = StreamingSpeechChunker(maxPendingCharacters: 40)
        let long = String(repeating: "word ", count: 20)
        let segments = chunker.consume(cumulative: long)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertLessThan(segments[0].count, long.count)
    }

    func testSafetyFlushDefaultIsAboutThreeHundredCharacters() {
        var chunker = StreamingSpeechChunker()
        let short = String(repeating: "word ", count: 40) // 200 chars, no terminator
        XCTAssertEqual(chunker.consume(cumulative: short), [])
        let clause = String(repeating: "word ", count: 50) + "still going, " + String(repeating: "word ", count: 20)
        let segments = chunker.consume(cumulative: clause)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments[0].contains(","))
    }

    func testFinishFlushesUnterminatedRemainder() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(chunker.consume(cumulative: "Still talking with no period"), [])
        XCTAssertEqual(
            chunker.finish(cumulative: "Still talking with no period"),
            ["Still talking with no period"]
        )
    }

    func testFlushesOnNewline() {
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(
            chunker.consume(cumulative: "Line one\nLine two continues"),
            ["Line one"]
        )
    }
}
