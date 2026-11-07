// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A user-defined task that runs (or fires a reminder) on a schedule — mirrors
/// the Python app's `ScheduledTask`.
///
/// `TaskSchedulerService` owns the runtime behaviour: it computes `nextRun` from
/// the schedule fields and registers local notifications. Many fields are
/// nullable because the same model serves several task flavours (one-off vs
/// recurring, prompt-driven LLM tasks vs action triggers).
@Model
public final class ScheduledTask {
    /// Stable identifier (UUID string), also used to derive the notification ID.
    public var id: String = ""
    /// Optional owning user.
    public var owner: String?
    /// Parent task id for nested subtasks (`nil` = top-level task).
    public var parentTaskID: String?
    /// Manual ordering hint among siblings.
    public var sortOrder: Int = 0
    /// Human-readable task name (used as the notification title).
    public var name: String = "Untitled Task"
    /// Prompt to run for LLM-style tasks (also used as notification body).
    public var prompt: String?
    /// Discriminator for what kind of work the task performs (e.g. "llm").
    public var taskType: String = "llm"
    /// Optional named action to invoke for non-LLM task types.
    public var action: String?
    /// Recurrence cadence as a `TaskSchedule` raw value (once/daily/weekly/...).
    public var schedule: String?
    /// Time-of-day "HH:mm" used by recurring schedules.
    public var scheduledTime: String?
    /// Day selector for weekly/monthly schedules.
    public var scheduledDay: Int?
    /// Absolute fire date for one-off ("once") schedules.
    public var scheduledDate: Date?
    /// Whether the task fires on a schedule or in response to an event.
    public var triggerType: String = "schedule"
    /// Name of the triggering event when `triggerType` is event-based.
    public var triggerEvent: String?
    /// Computed next/most-recent execution timestamps maintained by the scheduler.
    public var nextRun: Date?
    public var lastRun: Date?
    /// Lifecycle status as a `TaskStatus` raw value (active/paused/completed).
    public var status: String = TaskStatus.active.rawValue
    /// Where results are delivered (e.g. a chat "session").
    public var outputTarget: String = "session"
    /// Optional chat session the task reads from / writes to.
    public var sessionID: String?
    /// Optional model + endpoint overrides for LLM tasks.
    public var model: String?
    public var endpointURL: String?
    /// How many times the task has run so far.
    public var runCount: Int = 0
    /// Optional cron expression for advanced scheduling.
    public var cronExpression: String?
    /// Whether the scheduler should post local notifications for this task.
    public var notificationsEnabled: Bool = true

    /// Bookkeeping timestamps.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Creates a scheduled task; `id` defaults to a fresh UUID and the task
    /// starts in the active state.
    public init(
        id: String = UUID().uuidString,
        owner: String? = nil,
        parentTaskID: String? = nil,
        sortOrder: Int = 0,
        name: String = "Untitled Task",
        prompt: String? = nil,
        taskType: String = "llm",
        action: String? = nil,
        schedule: String? = nil,
        scheduledTime: String? = nil,
        scheduledDay: Int? = nil,
        scheduledDate: Date? = nil,
        triggerType: String = "schedule",
        triggerEvent: String? = nil,
        nextRun: Date? = nil,
        lastRun: Date? = nil,
        status: String = TaskStatus.active.rawValue,
        outputTarget: String = "session",
        sessionID: String? = nil,
        model: String? = nil,
        endpointURL: String? = nil,
        runCount: Int = 0,
        cronExpression: String? = nil,
        notificationsEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.owner = owner
        self.parentTaskID = parentTaskID
        self.sortOrder = sortOrder
        self.name = name
        self.prompt = prompt
        self.taskType = taskType
        self.action = action
        self.schedule = schedule
        self.scheduledTime = scheduledTime
        self.scheduledDay = scheduledDay
        self.scheduledDate = scheduledDate
        self.triggerType = triggerType
        self.triggerEvent = triggerEvent
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.status = status
        self.outputTarget = outputTarget
        self.sessionID = sessionID
        self.model = model
        self.endpointURL = endpointURL
        self.runCount = runCount
        self.cronExpression = cronExpression
        self.notificationsEnabled = notificationsEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Lifecycle states for a `ScheduledTask`, stored as the raw `status` string.
public enum TaskStatus: String, Sendable {
    /// Eligible to run and have notifications scheduled.
    case active
    /// Temporarily suspended; pending notifications are removed.
    case paused
    /// Finished and no longer scheduled.
    case completed
}

/// Recurrence cadences for a `ScheduledTask`, stored as the raw `schedule`
/// string. `CaseIterable` so the UI can offer them as choices.
public enum TaskSchedule: String, Sendable, CaseIterable {
    /// Fires a single time at `scheduledDate`.
    case once
    /// Repeats every day at `scheduledTime`.
    case daily
    /// Repeats weekly.
    case weekly
    /// Repeats monthly.
    case monthly
}
