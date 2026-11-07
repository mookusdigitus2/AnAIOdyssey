// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class VoiceReplayStoreTests: XCTestCase {
    func testRecordsLastReplyAndIgnoresBlank() {
        var store = VoiceReplayStore()
        XCTAssertFalse(store.canReplay)
        store.record("  Hello there. ")
        XCTAssertEqual(store.lastReply, "Hello there.")
        store.record("Second reply.")
        XCTAssertEqual(store.lastReply, "Second reply.")
        store.record("   ")
        XCTAssertEqual(store.lastReply, "Second reply.")
        store.clear()
        XCTAssertFalse(store.canReplay)
    }
}
