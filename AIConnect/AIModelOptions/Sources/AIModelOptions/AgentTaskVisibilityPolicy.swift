// SPDX-License-Identifier: MIT
import Foundation

/// Whether the multi-agent queue ("Agent Queue" in Tasks, plus the chat
/// `enqueue_agent_task` / `list_agent_tasks` tools) is offered.
///
/// Agent tasks are hidden in TestFlight and App Store builds while Chat and
/// Research learn to run in the background. Debug builds keep them so the
/// feature can still be developed. To bring them back for release, return
/// `true` from `isAgentQueueVisible(channel:)`.
public enum AgentTaskVisibilityPolicy {
    public enum BuildChannel: String, Sendable, Equatable {
        case debug
        case testFlight
        case appStore
    }

    public static func isAgentQueueVisible(channel: BuildChannel) -> Bool {
        channel == .debug
    }

    /// TestFlight installs carry a `sandboxReceipt`; anything else non-Debug is
    /// treated as a store build.
    public static func releaseChannel(receiptLastPathComponent: String?) -> BuildChannel {
        receiptLastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
    }

    public static var currentChannel: BuildChannel {
        #if DEBUG
        return .debug
        #else
        return releaseChannel(receiptLastPathComponent: Bundle.main.appStoreReceiptURL?.lastPathComponent)
        #endif
    }

    public static var isAgentQueueVisible: Bool {
        isAgentQueueVisible(channel: currentChannel)
    }
}
