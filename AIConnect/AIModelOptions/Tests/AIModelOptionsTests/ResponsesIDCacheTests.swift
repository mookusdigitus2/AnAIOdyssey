// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ResponsesIDCacheTests: XCTestCase {
    func testScopeIncludesConversationWhenPresent() {
        XCTAssertEqual(
            ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra"),
            "c1|gpt-6-astra"
        )
        XCTAssertEqual(
            ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra", conversationID: "chat-9"),
            "c1|gpt-6-astra|chat-9"
        )
        XCTAssertNotEqual(
            ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra", conversationID: "chat-9"),
            ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra", conversationID: "chat-10")
        )
    }

    func testTwoConversationsOnTheSameConnectionDoNotShareAnID() {
        var cache = ResponsesIDCache()
        cache.set("resp_a", scope: ResponsesIDCache.scope(connectionID: "openai", modelID: "gpt-6-astra", conversationID: "a"))
        cache.set("resp_b", scope: ResponsesIDCache.scope(connectionID: "openai", modelID: "gpt-6-astra", conversationID: "b"))
        XCTAssertEqual(
            cache.id(for: ResponsesIDCache.scope(connectionID: "openai", modelID: "gpt-6-astra", conversationID: "a")),
            "resp_a"
        )
        XCTAssertEqual(
            cache.id(for: ResponsesIDCache.scope(connectionID: "openai", modelID: "gpt-6-astra", conversationID: "b")),
            "resp_b"
        )
        XCTAssertNil(cache.id(for: ResponsesIDCache.scope(connectionID: "openai", modelID: "gpt-6-astra")))
    }

    func testRemovingAConnectionClearsEveryModelOnIt() {
        var cache = ResponsesIDCache()
        cache.set("resp_1", scope: ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra"))
        cache.set("resp_2", scope: ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-4o", conversationID: "x"))
        cache.set("resp_3", scope: ResponsesIDCache.scope(connectionID: "c2", modelID: "gpt-6-astra"))
        cache.remove(connectionID: "c1")
        XCTAssertNil(cache.id(for: ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-6-astra")))
        XCTAssertNil(cache.id(for: ResponsesIDCache.scope(connectionID: "c1", modelID: "gpt-4o", conversationID: "x")))
        XCTAssertEqual(cache.id(for: ResponsesIDCache.scope(connectionID: "c2", modelID: "gpt-6-astra")), "resp_3")
    }
}
