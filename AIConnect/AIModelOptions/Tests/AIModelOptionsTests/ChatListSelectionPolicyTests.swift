// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ChatListSelectionPolicyTests: XCTestCase {
    func testToggleSelectAllAndDeselectAll() {
        let ids = ["a", "b", "c"]
        XCTAssertFalse(ChatListSelectionPolicy.isAllSelected(current: [], allIDs: ids))
        let all = ChatListSelectionPolicy.toggleSelectAll(current: [], allIDs: ids)
        XCTAssertEqual(all, Set(ids))
        XCTAssertTrue(ChatListSelectionPolicy.isAllSelected(current: all, allIDs: ids))
        XCTAssertEqual(
            ChatListSelectionPolicy.toggleSelectAll(current: all, allIDs: ids),
            []
        )
        XCTAssertEqual(ChatListSelectionPolicy.selectAllTitle(isAllSelected: false), "Select All")
        XCTAssertEqual(ChatListSelectionPolicy.selectAllTitle(isAllSelected: true), "Deselect All")
        XCTAssertEqual(ChatListSelectionPolicy.toggleSelectAll(current: [], allIDs: []), [])
    }

    func testDeleteCopy() {
        XCTAssertEqual(ChatListSelectionPolicy.deleteButtonTitle(count: 12), "Delete 12 Chats")
        XCTAssertEqual(ChatListSelectionPolicy.deleteButtonTitle(count: 1), "Delete 1 Chat")
        XCTAssertEqual(ChatListSelectionPolicy.contextMenuTitle(count: 12), "Delete 12 Chats")
        XCTAssertEqual(ChatListSelectionPolicy.contextMenuTitle(count: 1), "Delete Chat")
        XCTAssertEqual(
            ChatListSelectionPolicy.confirmationSentence(count: 12),
            "Delete 12 chats? This can't be undone."
        )
        XCTAssertEqual(
            ChatListSelectionPolicy.confirmationSentence(count: 1),
            "Delete 1 chat? This can't be undone."
        )
        XCTAssertFalse(ChatListSelectionPolicy.canDelete(0))
        XCTAssertTrue(ChatListSelectionPolicy.canDelete(1))
    }

    func testOpenSessionClearsWhenDeleted() {
        XCTAssertEqual(
            ChatListSelectionPolicy.openSessionAfterDelete(openID: "keep", deletedIDs: ["gone"]),
            "keep"
        )
        XCTAssertNil(
            ChatListSelectionPolicy.openSessionAfterDelete(openID: "gone", deletedIDs: ["gone", "other"])
        )
        XCTAssertNil(
            ChatListSelectionPolicy.openSessionAfterDelete(openID: nil, deletedIDs: ["gone"])
        )
        XCTAssertEqual(
            ChatListSelectionPolicy.remainingSelection(["a", "b", "c"], afterDeleting: ["b"]),
            ["a", "c"]
        )
    }
}
