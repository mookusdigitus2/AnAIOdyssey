// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class WorkspaceNavigationPolicyTests: XCTestCase {
    func testPlusMaxLandscapeKeepsPhoneRoot() {
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: true,
                horizontalSizeClassIsRegular: true
            ),
            .phone
        )
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: true,
                horizontalSizeClassIsRegular: false
            ),
            .phone
        )
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: false,
                horizontalSizeClassIsRegular: true
            ),
            .tablet
        )
    }

    func testSizeClassChangeDoesNotRecreatePhoneRoot() {
        XCTAssertFalse(
            WorkspaceNavigationPolicy.shouldRecreateRoot(previous: .phone, next: .phone)
        )
        XCTAssertTrue(
            WorkspaceNavigationPolicy.shouldRecreateRoot(previous: .phone, next: .tablet)
        )
    }

    func testPhoneKeepsStackChatLayout() {
        XCTAssertTrue(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(idiomIsPhone: true))
        XCTAssertFalse(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(idiomIsPhone: false))
    }

    // iPhone Duo: the inner (unfolded) screen is regular in both directions and gets the
    // tablet shell; the outer screen is compact width and keeps the phone shell. Plus/Max
    // landscape is regular width but compact height, so it stays on the phone shell.
    func testRegularBothWaysOnPhoneGetsTabletRoot() {
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: true
            ),
            .tablet,
            "unfolded iPhone Duo inner screen"
        )
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: false
            ),
            .phone,
            "Plus/Max landscape keeps the phone root"
        )
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: true, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: true
            ),
            .phone,
            "portrait iPhone and the folded outer screen"
        )
        XCTAssertEqual(
            WorkspaceNavigationPolicy.rootKind(
                idiomIsPhone: false, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: true
            ),
            .tablet,
            "a narrow iPad window stays on the tablet root"
        )
    }

    func testChatLayoutFollowsTheRootOnFold() {
        XCTAssertTrue(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(
            idiomIsPhone: true, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: true))
        XCTAssertFalse(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(
            idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: true))
        XCTAssertTrue(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(
            idiomIsPhone: true, horizontalSizeClassIsRegular: true, verticalSizeClassIsRegular: false))
        XCTAssertFalse(WorkspaceNavigationPolicy.shouldUsePhoneChatLayout(
            idiomIsPhone: false, horizontalSizeClassIsRegular: false, verticalSizeClassIsRegular: false))
        // Folding or unfolding swaps the shell but keeps the open chat.
        XCTAssertFalse(WorkspaceNavigationPolicy.shouldClearOpenChat(reason: .sizeClassChange))
    }

    func testTextFitWidthComesFromTheViewNotTheScreen() {
        XCTAssertEqual(WorkspaceNavigationPolicy.textFitWidth(proposed: 300, containerWidth: 800), 300)
        XCTAssertEqual(WorkspaceNavigationPolicy.textFitWidth(proposed: nil, containerWidth: 412), 412)
        XCTAssertNil(WorkspaceNavigationPolicy.textFitWidth(proposed: nil, containerWidth: nil))
        XCTAssertNil(WorkspaceNavigationPolicy.textFitWidth(proposed: nil, containerWidth: 0))
        XCTAssertEqual(WorkspaceNavigationPolicy.textFitWidth(proposed: .infinity, containerWidth: 390), 390)
    }

    func testStoredOpenChatSurvivesRotationAndBackground() {
        XCTAssertEqual(WorkspaceNavigationPolicy.storedOpenChatID("chat-123"), "chat-123")
        XCTAssertEqual(WorkspaceNavigationPolicy.persistOpenChatID("chat-123"), "chat-123")
        XCTAssertNil(WorkspaceNavigationPolicy.storedOpenChatID(""))
        XCTAssertNil(WorkspaceNavigationPolicy.storedOpenChatID("  "))
        XCTAssertFalse(
            WorkspaceNavigationPolicy.shouldClearOpenChat(reason: .rotation)
        )
        XCTAssertFalse(
            WorkspaceNavigationPolicy.shouldClearOpenChat(reason: .sizeClassChange)
        )
        XCTAssertFalse(
            WorkspaceNavigationPolicy.shouldClearOpenChat(reason: .sceneBackground)
        )
        XCTAssertFalse(
            WorkspaceNavigationPolicy.shouldShowSessionList(
                storedOpenChatID: "chat-123",
                userBrowsingList: false
            )
        )
        XCTAssertTrue(
            WorkspaceNavigationPolicy.shouldShowSessionList(
                storedOpenChatID: "chat-123",
                userBrowsingList: true
            )
        )
    }

    func testRestoredTabDefaultsToChats() {
        XCTAssertEqual(WorkspaceNavigationPolicy.restoredPhoneTab(nil), "chats")
        XCTAssertEqual(WorkspaceNavigationPolicy.restoredPhoneTab(""), "chats")
        XCTAssertEqual(WorkspaceNavigationPolicy.restoredPhoneTab("tasks"), "tasks")
        XCTAssertEqual(WorkspaceNavigationPolicy.restoredTabletSection(nil), "chats")
        XCTAssertEqual(WorkspaceNavigationPolicy.restoredTabletSection("documents"), "documents")
    }

    func testUnexpectedTerminationPrompt() {
        XCTAssertTrue(
            UnexpectedTerminationPolicy.shouldPromptForAudioLog(
                cleanExitFlag: false,
                hasAudioLog: true
            )
        )
        XCTAssertFalse(
            UnexpectedTerminationPolicy.shouldPromptForAudioLog(
                cleanExitFlag: true,
                hasAudioLog: true
            )
        )
        XCTAssertFalse(
            UnexpectedTerminationPolicy.shouldPromptForAudioLog(
                cleanExitFlag: false,
                hasAudioLog: false
            )
        )
        XCTAssertEqual(
            UnexpectedTerminationPolicy.promptCopy,
            "An AI Odyssey closed unexpectedly. Share the audio log to help fix it?"
        )
    }
}
