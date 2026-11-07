// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Audit/history entry for an `AgentTask` (supports iterative updates and handoff).
@Model
public final class AgentTaskEvent {
    public var id: String = ""
    public var taskID: String = ""
    /// `human`, `ai`, or `system`.
    public var actorType: String = "system"
    public var actorID: String?
    /// Short action label (created, claimed, handoff, completed, note, …).
    public var action: String = ""
    public var message: String = ""
    public var createdAt: Date = Date()

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        actorType: String = "system",
        actorID: String? = nil,
        action: String,
        message: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.actorType = actorType
        self.actorID = actorID
        self.action = action
        self.message = message
        self.createdAt = createdAt
    }
}
