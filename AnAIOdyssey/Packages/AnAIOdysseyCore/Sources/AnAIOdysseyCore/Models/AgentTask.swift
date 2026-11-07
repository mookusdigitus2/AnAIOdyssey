// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A unit of work in the multi-agent central queue (distinct from `ScheduledTask`,
/// which handles notification-based reminders).
@Model
public final class AgentTask {
    public var id: String = ""
    public var title: String = "Untitled"
    /// Assignment / prompt for the agent.
    public var assignment: String = ""
    /// Queue lifecycle status (`AgentTaskStatus` raw value).
    public var status: String = AgentTaskStatus.paused.rawValue
    /// Legacy assignee id; unused after run-with-assignee was removed. Kept so
    /// existing CloudKit / archive records still decode.
    public var assigneeAgentID: String?
    /// Controller agent that created or owns routing for this task.
    public var controllerAgentID: String?
    /// Legacy handoff target. Unused in the UI after pause/continue replaced it.
    public var handoffTarget: String?
    /// Inline context (small payloads); large context uses `contextFileName`.
    public var contextInline: String?
    /// Filename under Application Support agent-contexts/.
    public var contextFileName: String?
    public var parentTaskID: String?
    public var sessionID: String?
    public var priority: Int = 0
    public var resultSummary: String?
    /// Live status detail, e.g. "updating Trip Plan".
    public var currentAction: String?
    /// JSON array of Document/Research items this run created or edited.
    public var changeLogJSON: String = "[]"
    /// JSON array of `{role,content}` turns so Continue can resume mid-run.
    public var conversationJSON: String?
    /// Short error shown as `Error: …` when status is `error`.
    public var errorMessage: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(
        id: String = UUID().uuidString,
        title: String = "Untitled",
        assignment: String = "",
        status: String = AgentTaskStatus.paused.rawValue,
        assigneeAgentID: String? = nil,
        controllerAgentID: String? = nil,
        handoffTarget: String? = nil,
        contextInline: String? = nil,
        contextFileName: String? = nil,
        parentTaskID: String? = nil,
        sessionID: String? = nil,
        priority: Int = 0,
        resultSummary: String? = nil,
        currentAction: String? = nil,
        changeLogJSON: String = "[]",
        conversationJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.assignment = assignment
        self.status = status
        self.assigneeAgentID = assigneeAgentID
        self.controllerAgentID = controllerAgentID
        self.handoffTarget = handoffTarget
        self.contextInline = contextInline
        self.contextFileName = contextFileName
        self.parentTaskID = parentTaskID
        self.sessionID = sessionID
        self.priority = priority
        self.resultSummary = resultSummary
        self.currentAction = currentAction
        self.changeLogJSON = changeLogJSON
        self.conversationJSON = conversationJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Run states for agent tasks: auto-start, pause/continue, and stop.
public enum AgentTaskStatus: String, Sendable, CaseIterable {
    case running
    case paused
    case stopped
    case done
    case error

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    /// Maps pre-pause/continue statuses onto this machine.
    public static func migrateStored(_ raw: String) -> AgentTaskStatus {
        switch raw {
        case running.rawValue, "in_progress", "claimed":
            return .running
        case paused.rawValue, "pending", "blocked", "handoff_human", "handoff_ai":
            return .paused
        case stopped.rawValue:
            return .stopped
        case done.rawValue, "completed":
            return .done
        case error.rawValue, "failed":
            return .error
        default:
            return .paused
        }
    }

    /// After a cold start, running work is paused so we do not resume HTTP blindly.
    public static func afterLaunchRecovery(_ status: AgentTaskStatus) -> AgentTaskStatus {
        status == .running ? .paused : status
    }
}
