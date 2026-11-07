// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class StreamTerminationTests: XCTestCase {
    func testFinishReasonLengthIsACutoff() {
        let term = StreamTextCodecTermination.termination(
            in: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#
        )
        XCTAssertEqual(term, .length)
        XCTAssertTrue(term?.isCutoff == true)
        XCTAssertTrue(term?.userMessage.contains("cut off (length)") == true)
    }

    func testFinishReasonContentFilterIsACutoff() {
        XCTAssertEqual(
            StreamTextCodecTermination.termination(
                in: #"{"choices":[{"finish_reason":"content_filter"}]}"#
            ),
            .contentFilter
        )
    }

    func testFinishReasonStopIsNotACutoff() {
        let term = StreamTextCodecTermination.termination(
            in: #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        )
        XCTAssertEqual(term, .stop)
        XCTAssertFalse(term?.isCutoff == true)
    }

    func testMidStreamErrorIsSurfaced() {
        let term = StreamTextCodecTermination.termination(
            in: #"{"error":{"message":"engine overloaded"}}"#
        )
        XCTAssertEqual(term, .error("engine overloaded"))
        XCTAssertTrue(term?.isFailure == true)
    }

    func testResponsesIncompleteLength() {
        let json = #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        XCTAssertEqual(StreamTextCodecTermination.termination(in: json), .length)
        let event = OpenAIRequestCodec.parseResponsesStreamEvent(json)
        XCTAssertEqual(event?.termination, .length)
        XCTAssertTrue(event?.errorMessage?.contains("cut off") == true)
    }
}
