// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// OpenRouter's HTTP-Referer comes from the host-configurable project homepage.
final class OpenRouterAttributionTests: XCTestCase {
    override func tearDown() {
        AIProjectHomepage.override = nil
        super.tearDown()
    }

    func testRefererUsesTheProjectHomepage() {
        AIProjectHomepage.override = "https://host.example/app"
        let headers = OpenAICompatibleAPI.requestHeaders(
            baseURL: "https://openrouter.ai/api/v1", apiKey: "k", streaming: false)
        XCTAssertEqual(headers["HTTP-Referer"], "https://host.example/app")
    }

    func testRefererDefaultsToThePlaceholder() {
        let headers = OpenAICompatibleAPI.requestHeaders(
            baseURL: "https://openrouter.ai/api/v1", apiKey: "k", streaming: false)
        XCTAssertEqual(headers["HTTP-Referer"], AIProjectHomepage.url)
        XCTAssertFalse(headers["HTTP-Referer"]?.contains("mookus" + "digitus2") ?? true)
    }
}
