// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class AgentTaskVisibilityPolicyTests: XCTestCase {
    func testDebugBuildsShowAgentTasks() {
        XCTAssertTrue(AgentTaskVisibilityPolicy.isAgentQueueVisible(channel: .debug))
    }

    func testTestFlightBuildsHideAgentTasks() {
        XCTAssertFalse(AgentTaskVisibilityPolicy.isAgentQueueVisible(channel: .testFlight))
    }

    func testAppStoreBuildsHideAgentTasks() {
        XCTAssertFalse(AgentTaskVisibilityPolicy.isAgentQueueVisible(channel: .appStore))
    }

    func testReleaseChannelFromReceipt() {
        XCTAssertEqual(
            AgentTaskVisibilityPolicy.releaseChannel(receiptLastPathComponent: "sandboxReceipt"),
            .testFlight
        )
        XCTAssertEqual(
            AgentTaskVisibilityPolicy.releaseChannel(receiptLastPathComponent: "receipt"),
            .appStore
        )
        // No receipt (ad-hoc / direct Release install): still hidden.
        XCTAssertEqual(
            AgentTaskVisibilityPolicy.releaseChannel(receiptLastPathComponent: nil),
            .appStore
        )
    }

    func testTestRunsAreDebugChannel() {
        // Tests build in Debug, so the live value must keep agent tasks visible.
        XCTAssertEqual(AgentTaskVisibilityPolicy.currentChannel, .debug)
        XCTAssertTrue(AgentTaskVisibilityPolicy.isAgentQueueVisible)
    }
}
