// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

/// Markdown must never reach TTS: it garbles speech on every provider.
final class SpeechMarkdownSanitizerTests: XCTestCase {
    private func clean(_ text: String) -> String? { SpeechMarkdownSanitizer.speakable(text) }

    func testEmphasisMarkersAreRemoved() {
        XCTAssertEqual(clean("This is **bold**, *italic*, __strong__ and _em_."), "This is bold, italic, strong and em.")
    }

    func testSnakeCaseUnderscoresInsideWordsSurvive() {
        XCTAssertEqual(clean("Set max_tokens to 10."), "Set max_tokens to 10.")
    }

    func testStrikethroughIsRemoved() {
        XCTAssertEqual(clean("It was ~~wrong~~ right."), "It was wrong right.")
    }

    func testHeadersAreRemoved() {
        XCTAssertEqual(clean("## Summary"), "Summary")
        XCTAssertEqual(clean("### Next steps ###"), "Next steps")
    }

    func testListMarkersAreRemoved() {
        XCTAssertEqual(clean("- apples\n* pears\n+ plums\n1. first\n2) second"), "apples\npears\nplums\nfirst\nsecond")
    }

    func testBlockquoteMarkersAreRemoved() {
        XCTAssertEqual(clean("> Quoted line\n> > nested"), "Quoted line\nnested")
    }

    func testInlineCodeKeepsItsText() {
        XCTAssertEqual(clean("Run `swift test` now."), "Run swift test now.")
    }

    func testFencedCodeBlocksAreSkippedEntirely() {
        let text = "Here is code:\n```swift\nlet x = 1. print(x)\n```\nThat's it."
        XCTAssertEqual(clean(text), "Here is code:\nThat's it.")
        XCTAssertEqual(clean("~~~\nrm -rf /\n~~~"), nil)
    }

    func testTablesLoseTheirPipesAndSeparatorRow() {
        let table = "| Name | Age |\n| --- | :---: |\n| Ann | 30 |"
        XCTAssertEqual(clean(table), "Name, Age\nAnn, 30")
    }

    func testHorizontalRulesAreDropped() {
        XCTAssertEqual(clean("Above\n---\n***\n___\nBelow"), "Above\nBelow")
    }

    func testLinksBecomeTheirLabel() {
        XCTAssertEqual(clean("See [the docs](https://example.com/a_b) today."), "See the docs today.")
    }

    func testBareURLsAreDropped() {
        XCTAssertEqual(clean("More at https://example.com/path?q=1 and www.apple.com."), "More at and.")
    }

    func testImagesBecomeAltTextOrNothing() {
        XCTAssertEqual(clean("Look: ![a red fox](fox.png)"), "Look: a red fox")
        XCTAssertNil(clean("![](spacer.gif)"))
    }

    func testMarkupOnlyLineIsNotSpoken() {
        XCTAssertNil(clean("**"))
        XCTAssertNil(clean("> "))
    }

    // MARK: Streamed chunks

    func testBoldSplitAcrossChunksNeverSpeaksAsterisks() {
        var chunker = StreamingSpeechChunker()
        var spoken: [String] = []
        for cumulative in ["Here is **", "Here is **bo", "Here is **bold** te", "Here is **bold** text. Then "] {
            spoken += chunker.consume(cumulative: cumulative)
        }
        spoken += chunker.finish(cumulative: "Here is **bold** text. Then **more**")
        XCTAssertEqual(spoken, ["Here is bold text.", "Then more"])
        XCTAssertFalse(spoken.joined().contains("*"))
    }

    func testSentenceBoundaryInsideBoldLeavesNoLoneMarkers() {
        var chunker = StreamingSpeechChunker()
        let spoken = chunker.finish(cumulative: "**Warning. Be careful.** Next")
        XCTAssertEqual(spoken, ["Warning.", "Be careful.", "Next"])
    }

    func testFencedBlockStreamedLineByLineIsSkipped() {
        var chunker = StreamingSpeechChunker()
        var spoken: [String] = []
        let full = "Try this:\n```\nlet a = 1. let b = 2.\nprint(a)\n```\nDone. "
        var cumulative = ""
        for character in full {
            cumulative.append(character)
            spoken += chunker.consume(cumulative: cumulative)
        }
        spoken += chunker.finish(cumulative: full)
        XCTAssertEqual(spoken, ["Try this:", "Done."])
    }

    func testListAndHeaderLinesStreamClean() {
        var chunker = StreamingSpeechChunker()
        let spoken = chunker.finish(cumulative: "# Plan\n1. Buy milk\n- See [site](https://x.y)\n")
        XCTAssertEqual(spoken, ["Plan", "Buy milk", "See site"])
    }
}
