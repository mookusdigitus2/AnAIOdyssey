// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AIModelOptions
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice

final class StreamingSpeechSegmenterTests: XCTestCase {
    func testEmitsCompletedSentencesIncrementally() {
        var segmenter = StreamingSpeechSegmenter()

        XCTAssertEqual(segmenter.consume(cumulative: "Hello"), [])
        XCTAssertEqual(
            segmenter.consume(cumulative: "Hello there. How"),
            ["Hello there."]
        )
        XCTAssertEqual(
            segmenter.consume(cumulative: "Hello there. How are you? Fine"),
            ["How are you?"]
        )
        XCTAssertEqual(
            segmenter.finish(cumulative: "Hello there. How are you? Fine day"),
            ["Fine day"]
        )
    }

    func testDoesNotReemitAlreadySpokenText() {
        var segmenter = StreamingSpeechSegmenter()
        let first = segmenter.consume(cumulative: "One. Two. ")
        XCTAssertEqual(first, ["One.", "Two."])
        XCTAssertEqual(segmenter.consume(cumulative: "One. Two. Three."), [])
        XCTAssertEqual(segmenter.finish(cumulative: "One. Two. Three."), ["Three."])
    }

    func testDoesNotRespeakWhenStreamIsRewritten() {
        var segmenter = StreamingSpeechSegmenter()
        // A sentence followed by a newline is committed as soon as it streams in.
        XCTAssertEqual(
            segmenter.consume(cumulative: "Let me check that.\n"),
            ["Let me check that."]
        )
        // The streaming filter later strips a tool fence and trims trailing
        // whitespace, so the cumulative text no longer has the committed prefix.
        // Nothing new was added, so nothing may be re-spoken.
        XCTAssertEqual(segmenter.consume(cumulative: "Let me check that."), [])
        XCTAssertEqual(segmenter.finish(cumulative: "Let me check that."), [])
    }

    func testFinishAfterRewriteSpeaksOnlyTheNewTail() {
        var segmenter = StreamingSpeechSegmenter()
        XCTAssertEqual(
            segmenter.consume(cumulative: "First sentence. And then\n"),
            ["First sentence.", "And then"]
        )
        // Final text diverges after the shared prefix; only the tail beyond the
        // common prefix is spoken — never the whole reply again.
        XCTAssertEqual(
            segmenter.finish(cumulative: "First sentence. And then some more."),
            ["some more."]
        )
    }

    func testOutOfOrderCumulativeUpdatesDoNotRespeak() {
        var segmenter = StreamingSpeechSegmenter()
        XCTAssertEqual(
            segmenter.consume(cumulative: "One. Two. Three."),
            ["One.", "Two."]
        )
        // A stale (shorter) cumulative snapshot arrives late; it is fully
        // contained in what was already handled, so nothing is emitted.
        XCTAssertEqual(segmenter.consume(cumulative: "One. Two."), [])
        XCTAssertEqual(segmenter.finish(cumulative: "One. Two. Three."), ["Three."])
    }

    func testMarkSpokenSkipsHandedOverTextButSpeaksTheTail() {
        var segmenter = StreamingSpeechSegmenter()
        // Another transport (the WebSocket path) already synthesized this much
        // before failing over; the HTTP fallback must not replay it.
        segmenter.markSpoken(cumulative: "One. Two. ")
        XCTAssertEqual(segmenter.consume(cumulative: "One. Two. Three. Fo"), ["Three."])
        XCTAssertEqual(segmenter.finish(cumulative: "One. Two. Three. Four"), ["Four"])
    }

    func testResetsWhenCumulativeTextShrinks() {
        var segmenter = StreamingSpeechSegmenter()
        _ = segmenter.consume(cumulative: "First answer. More")
        // New agent round starts with a shorter stream.
        XCTAssertEqual(
            segmenter.consume(cumulative: "Second round begins. "),
            ["Second round begins."]
        )
    }

    func testStripsLightMarkdownForSpeech() {
        XCTAssertEqual(
            StreamingSpeechSegmenter.speakableText("**Bold** and [link](https://example.com)"),
            "Bold and link"
        )
        XCTAssertNil(StreamingSpeechSegmenter.speakableText("   "))
    }

    func testFlushesOnDoubleNewline() {
        var segmenter = StreamingSpeechSegmenter()
        XCTAssertEqual(
            segmenter.consume(cumulative: "Paragraph one\n\nNext"),
            ["Paragraph one"]
        )
    }

    func testForceBreaksVeryLongPhrases() {
        var segmenter = StreamingSpeechSegmenter(maxPendingCharacters: 40)
        let long = String(repeating: "word ", count: 20) // 100 chars, no sentence end
        let segments = segmenter.consume(cumulative: long)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertLessThan(segments[0].count, long.count)
    }

    func testFlushesOnSingleNewline() {
        var segmenter = StreamingSpeechSegmenter()
        XCTAssertEqual(
            segmenter.consume(cumulative: "Line one\nLine two continues"),
            ["Line one"]
        )
    }

    func testWaitsForAFullSentenceBeforeTheFirstChunk() {
        var segmenter = StreamingSpeechSegmenter()
        XCTAssertEqual(
            segmenter.consume(cumulative: "I'll research Scout's latest vehicles for you now "),
            []
        )
        XCTAssertEqual(
            segmenter.consume(cumulative: "I'll research Scout's latest vehicles for you now. Next"),
            ["I'll research Scout's latest vehicles for you now."]
        )
    }
}

@MainActor
final class SafeBlockLengthTests: XCTestCase {
    func testHoldsBackTextWithoutBoundary() {
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "The qui"), 0)
        // Punctuation at the very end (no following whitespace yet) is not a
        // boundary — the next token might continue it (e.g. "3." → "3.14").
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "Hello."), 0)
    }

    func testCutsAfterPunctuationPlusWhitespace() {
        XCTAssertEqual(
            ElevenLabsTTSCodec.safeBlockLength(of: "Hello there. How are"),
            13 // "Hello there. "
        )
        XCTAssertEqual(
            ElevenLabsTTSCodec.safeBlockLength(of: "One, two and thr"),
            5 // "One, "
        )
    }

    func testCutsAtLineFeedAndCRLF() {
        XCTAssertEqual(
            ElevenLabsTTSCodec.safeBlockLength(of: "Line one\nnext"),
            9 // through the \n
        )
        XCTAssertEqual(
            ElevenLabsTTSCodec.safeBlockLength(of: "Line one\r\nnext"),
            9 // through the \r\n, which is a single Character (grapheme cluster)
        )
    }

    func testDoesNotSplitDecimalsOrURLs() {
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "pi is 3.14159 and mo"), 0)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "see https://example.com/a.b?c=d"), 0)
    }

    func testClosingQuotesStayWithSentence() {
        XCTAssertEqual(
            ElevenLabsTTSCodec.safeBlockLength(of: "He said \"stop.\" Then left"),
            16 // «He said "stop." »
        )
    }
}
