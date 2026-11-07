// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class HTTPRetryPolicyTests: XCTestCase {
    func testRetryableStatusesBeforeAnyStreamBytes() {
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(statusCode: 429, attempt: 1, receivedStreamBytes: false))
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(statusCode: 503, attempt: 3, receivedStreamBytes: false))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(statusCode: 429, attempt: 1, receivedStreamBytes: true))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(statusCode: 400, attempt: 1, receivedStreamBytes: false))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(statusCode: 503, attempt: 4, receivedStreamBytes: false))
    }

    func testHardQuotaLimitsAreNotRetried() {
        let planLimit = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#.utf8)
        let noCredit = Data(#"{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"quota"}}"#.utf8)
        let rateLimit = Data(#"{"error":{"type":"requests","code":"rate_limit_exceeded","message":"slow down"}}"#.utf8)
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(statusCode: 429, attempt: 1, receivedStreamBytes: false, body: planLimit))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(statusCode: 429, attempt: 1, receivedStreamBytes: false, body: noCredit))
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(statusCode: 429, attempt: 1, receivedStreamBytes: false, body: rateLimit))
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(statusCode: 503, attempt: 1, receivedStreamBytes: false, body: Data("oops".utf8)))
    }

    func testRetryAfterSecondsAndMillisecondsWin() {
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 1, retryAfter: "2"), 2)
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 1, retryAfterMilliseconds: "1500"), 1.5)
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 1, retryAfter: "1", retryAfterMilliseconds: "250"), 0.25)
    }

    func testRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_007)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: later)
        XCTAssertEqual(
            HTTPRetryPolicy.delaySeconds(attempt: 1, retryAfter: header, now: now),
            7,
            accuracy: 0.01
        )
    }

    func testExponentialFallback() {
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 1), 0.5)
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 2), 1)
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 4), 4)
        XCTAssertEqual(HTTPRetryPolicy.delaySeconds(attempt: 6), 8)
    }

    func testUsageParserReadsChatAndResponsesShapes() {
        let chat = TokenUsage.parse(json: #"{"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15}}"#)
        XCTAssertEqual(chat?.inputTokens, 11)
        XCTAssertEqual(chat?.outputTokens, 4)
        XCTAssertEqual(chat?.totalTokens, 15)
        let responses = TokenUsage.parse(
            json: #"{"type":"response.completed","response":{"usage":{"input_tokens":20,"output_tokens":5}}}"#
        )
        XCTAssertEqual(responses?.inputTokens, 20)
        XCTAssertEqual(responses?.outputTokens, 5)
    }
}
