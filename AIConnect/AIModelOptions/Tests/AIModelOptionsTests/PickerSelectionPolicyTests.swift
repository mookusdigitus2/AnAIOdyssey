// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class PickerSelectionPolicyTests: XCTestCase {
    func testPrependsRecognizedStoredKeyDroppedByNewestTen() {
        let listed = (3...12).reversed().map { "custom-chat-\($0)" }
        let stored = "custom-chat-1"
        let visible = PickerSelectionPolicy.visibleKeys(
            listed: listed,
            stored: stored,
            storedIsRecognized: true
        )
        XCTAssertEqual(visible.first, stored)
        XCTAssertEqual(
            PickerSelectionPolicy.resolvedKey(stored: stored, visible: visible, fallback: listed.first),
            stored
        )
    }

    func testDoesNotDuplicateStoredKeyAlreadyListed() {
        let listed = ["remote|a|gpt-6-astra", "remote|a|gpt-4o"]
        let visible = PickerSelectionPolicy.visibleKeys(
            listed: listed,
            stored: listed[0],
            storedIsRecognized: true
        )
        XCTAssertEqual(visible, listed)
    }

    func testEmptyStoredSnapsToFallback() {
        let listed = ["appleFoundation|apple_foundation", "remote|a|gpt-6-astra"]
        let visible = PickerSelectionPolicy.visibleKeys(
            listed: listed,
            stored: "",
            storedIsRecognized: false
        )
        XCTAssertEqual(visible, listed)
        XCTAssertEqual(
            PickerSelectionPolicy.resolvedKey(stored: "", visible: visible, fallback: listed.first),
            listed.first
        )
    }

    func testUnrecognizedStoredSnapsToFallback() {
        let listed = ["remote|a|gpt-6-astra"]
        let stored = "remote|missing|stale-model"
        let visible = PickerSelectionPolicy.visibleKeys(
            listed: listed,
            stored: stored,
            storedIsRecognized: false
        )
        XCTAssertEqual(visible, listed)
        XCTAssertEqual(
            PickerSelectionPolicy.resolvedKey(stored: stored, visible: visible, fallback: listed.first),
            listed.first
        )
    }
}
