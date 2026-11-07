// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftUI
import UserNotifications

/// Errors thrown by `TaskSchedulerService`.
public enum TaskSchedulerError: Error, LocalizedError {
    /// The user declined (or hasn't granted) notification permission.
    case notificationsDenied
    /// The task's schedule fields couldn't be turned into a fire date.
    case invalidSchedule
    /// No task matched the given id.
    case taskNotFound(String)
    /// Notification could not be registered with the system.
    case schedulingFailed(String)

    /// User-facing description for surfacing in alerts.
    public var errorDescription: String? {
        switch self {
        case .notificationsDenied:
            "Notification permission was denied. Enable notifications for \(AppBranding.appName) in Settings."
        case .invalidSchedule:
            "The task schedule is invalid or the next run time is in the past."
        case .taskNotFound(let id):
            "Scheduled task '\(id)' was not found."
        case .schedulingFailed(let message):
            "Could not schedule notification: \(message)"
        }
    }
}

/// Authorization state for local notification reminders.
public enum NotificationAuthorizationState: String, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    public var isUsable: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

/// Schedules `ScheduledTask`s as local notifications and keeps their `nextRun`
/// in sync.
///
/// Owns the runtime scheduling logic on top of the storage-only
/// `TaskRepositoryProtocol`: it computes fire dates from the task's schedule
/// fields, requests notification permission, and registers/cancels
/// `UNNotificationRequest`s. `@MainActor` because it coordinates the
/// main-actor-bound repository and UserNotifications.
@MainActor
public final class TaskSchedulerService {
    /// Storage for the tasks being scheduled.
    private let tasks: any TaskRepositoryProtocol
    /// System notification center used to schedule/cancel reminders.
    private let notificationCenter = UNUserNotificationCenter.current()

    /// Injects the task repository.
    public init(tasks: any TaskRepositoryProtocol) {
        self.tasks = tasks
    }

    /// Current notification permission state.
    public func authorizationState() async -> NotificationAuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Registers this process as the notification center delegate (call once at launch).
    public static func install(delegate: UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Ensures notification permission is granted, requesting it once if the user
    /// hasn't been asked yet.
    ///
    /// Treats provisional/ephemeral authorization as sufficient; throws
    /// `notificationsDenied` if permission is unavailable so callers can surface
    /// the problem before relying on reminders.
    public func requestNotificationAccessIfNeeded() async throws {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            // Already permitted (any flavor) — nothing to do.
            return
        case .notDetermined:
            // First time: prompt the user.
            #if os(macOS)
            let options: UNAuthorizationOptions = [.alert, .sound]
            #else
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            #endif
            let granted = try await notificationCenter.requestAuthorization(options: options)
            guard granted else { throw TaskSchedulerError.notificationsDenied }
        default:
            // Explicitly denied/restricted.
            throw TaskSchedulerError.notificationsDenied
        }
    }

    /// Creates a task, computes its first `nextRun`, and schedules a notification
    /// for it when enabled.
    ///
    /// Persists via the repository, then back-fills the computed run time with a
    /// follow-up update. Returns the created `ScheduledTask`.
    @discardableResult
    public func createTask(
        name: String,
        prompt: String?,
        schedule: TaskSchedule,
        scheduledTime: String?,
        scheduledDate: Date?,
        sessionID: String? = nil,
        parentTaskID: String? = nil
    ) async throws -> ScheduledTask {
        try await requestNotificationAccessIfNeeded()

        // Derive the first fire date from the schedule.
        let nextRun = Self.computeNextRun(
            schedule: schedule.rawValue,
            scheduledTime: scheduledTime,
            scheduledDate: scheduledDate
        )

        // Persist the task, then back-fill the computed nextRun and active status.
        let task = try tasks.createTask(
            name: name,
            prompt: prompt,
            schedule: schedule.rawValue,
            scheduledTime: scheduledTime,
            scheduledDate: scheduledDate,
            sessionID: sessionID,
            parentTaskID: parentTaskID
        )
        try tasks.updateTask(
            id: task.id,
            name: nil,
            prompt: nil,
            schedule: nil,
            scheduledTime: nil,
            scheduledDate: nil,
            status: TaskStatus.active.rawValue,
            nextRun: nextRun
        )

        // Register the reminder if the task wants one and has a valid fire date.
        guard let updated = try tasks.fetchTask(id: task.id) else {
            throw TaskSchedulerError.taskNotFound(task.id)
        }
        if updated.notificationsEnabled {
            guard let nextRun else {
                throw TaskSchedulerError.invalidSchedule
            }
            try await scheduleNotification(for: updated, fireDate: nextRun)
        }
        return updated
    }

    /// Resolves the next fire date, recomputing from schedule when the stored date is stale.
    public func resolvedNextRun(for task: ScheduledTask, after: Date = .now) -> Date? {
        if let nextRun = task.nextRun, nextRun > after {
            return nextRun
        }
        return Self.computeNextRun(
            schedule: task.schedule,
            scheduledTime: task.scheduledTime,
            scheduledDate: task.scheduledDate,
            after: after
        )
    }

    /// Called when a scheduled notification fires: advances recurring tasks and re-arms.
    public func handleTaskFired(id: String) async throws {
        guard let task = try tasks.fetchTask(id: id) else {
            throw TaskSchedulerError.taskNotFound(id)
        }
        guard task.status == TaskStatus.active.rawValue else { return }

        let now = Date()
        if task.schedule != TaskSchedule.once.rawValue {
            let nextRun = Self.computeNextRun(
                schedule: task.schedule,
                scheduledTime: task.scheduledTime,
                scheduledDate: task.scheduledDate,
                after: now
            )
            try tasks.updateTask(
                id: id,
                name: nil,
                prompt: nil,
                schedule: nil,
                scheduledTime: nil,
                scheduledDate: nil,
                status: TaskStatus.active.rawValue,
                nextRun: nextRun
            )
            if let updated = try tasks.fetchTask(id: id), updated.notificationsEnabled, let nextRun {
                try await scheduleNotification(for: updated, fireDate: nextRun)
            }
        } else {
            try tasks.updateTask(
                id: id,
                name: nil,
                prompt: nil,
                schedule: nil,
                scheduledTime: nil,
                scheduledDate: nil,
                status: TaskStatus.completed.rawValue,
                nextRun: nil
            )
            notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIDs(for: id))
        }
    }

    /// Returns task metadata for notification handling.
    public func fetchTask(id: String) throws -> ScheduledTask? {
        try tasks.fetchTask(id: id)
    }

    /// Lists tasks, optionally filtered by status (convenience over the raw
    /// string repository API).
    public func listTasks(status: TaskStatus? = nil) throws -> [ScheduledTask] {
        try tasks.listTasks(status: status?.rawValue)
    }

    /// Direct subtasks of `parentTaskID` (or top-level tasks when `nil`),
    /// optionally filtered by status.
    public func listSubtasks(parentTaskID: String?, status: TaskStatus? = nil) throws -> [ScheduledTask] {
        try tasks.listSubtasks(parentTaskID: parentTaskID, status: status?.rawValue)
    }

    /// Pauses a task: marks it paused and removes its pending notification.
    public func pauseTask(id: String) async throws {
        guard let task = try tasks.fetchTask(id: id) else {
            throw TaskSchedulerError.taskNotFound(id)
        }
        try tasks.updateTask(
            id: id,
            name: nil,
            prompt: nil,
            schedule: nil,
            scheduledTime: nil,
            scheduledDate: nil,
            status: TaskStatus.paused.rawValue,
            nextRun: task.nextRun
        )
        // Cancel the scheduled reminder while paused.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIDs(for: id))
    }

    /// Resumes a paused task: reactivates it and re-schedules its notification,
    /// recomputing `nextRun` if it no longer has one.
    public func resumeTask(id: String) async throws {
        guard let task = try tasks.fetchTask(id: id) else {
            throw TaskSchedulerError.taskNotFound(id)
        }
        // Recompute next run when the stored date is stale (e.g. paused across fire time).
        let nextRun = resolvedNextRun(for: task)
        try tasks.updateTask(
            id: id,
            name: nil,
            prompt: nil,
            schedule: nil,
            scheduledTime: nil,
            scheduledDate: nil,
            status: TaskStatus.active.rawValue,
            nextRun: nextRun
        )
        // Re-arm the reminder for the (re)activated task.
        if let updated = try tasks.fetchTask(id: id), updated.notificationsEnabled, let nextRun {
            try await scheduleNotification(for: updated, fireDate: nextRun)
        }
    }

    /// Marks a task completed and cancels any pending notification.
    public func completeTask(id: String) async throws {
        guard let task = try tasks.fetchTask(id: id) else {
            throw TaskSchedulerError.taskNotFound(id)
        }
        try tasks.updateTask(
            id: id,
            name: nil,
            prompt: nil,
            schedule: nil,
            scheduledTime: nil,
            scheduledDate: nil,
            status: TaskStatus.completed.rawValue,
            nextRun: nil
        )
        notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIDs(for: id))
        _ = task
    }

    /// Reactivates a completed or paused task and re-schedules its next reminder when applicable.
    public func reactivateTask(id: String) async throws {
        guard let task = try tasks.fetchTask(id: id) else {
            throw TaskSchedulerError.taskNotFound(id)
        }
        let nextRun = resolvedNextRun(for: task)
        try tasks.updateTask(
            id: id,
            name: nil,
            prompt: nil,
            schedule: nil,
            scheduledTime: nil,
            scheduledDate: nil,
            status: TaskStatus.active.rawValue,
            nextRun: nextRun
        )
        if let updated = try tasks.fetchTask(id: id), updated.notificationsEnabled, let nextRun {
            try await scheduleNotification(for: updated, fireDate: nextRun)
        }
    }

    /// Deletes a task and cancels its pending notification.
    public func deleteTask(id: String) throws {
        try tasks.deleteTask(id: id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIDs(for: id))
    }

    /// Re-registers notifications for every active task.
    ///
    /// Intended to run at launch, since pending local notifications don't survive
    /// reinstalls/restores. Tasks without a resolvable fire date are skipped.
    public func rescheduleAllActiveTasks() async throws {
        let activeTasks = try tasks.listTasks(status: TaskStatus.active.rawValue)
        let withNotifications = activeTasks.filter(\.notificationsEnabled).count
        // Launch only asks when there are reminders to keep (e.g. synced from another device);
        // otherwise the prompt waits for the first scheduled task.
        guard NotificationPromptPolicy.shouldAsk(.launch(activeTasksWithNotifications: withNotifications)) else { return }
        try await requestNotificationAccessIfNeeded()
        for task in activeTasks where task.notificationsEnabled {
            guard let nextRun = resolvedNextRun(for: task) else {
                continue
            }
            try tasks.updateTask(
                id: task.id,
                name: nil,
                prompt: nil,
                schedule: nil,
                scheduledTime: nil,
                scheduledDate: nil,
                status: TaskStatus.active.rawValue,
                nextRun: nextRun
            )
            if let updated = try tasks.fetchTask(id: task.id) {
                try await scheduleNotification(for: updated, fireDate: nextRun)
            }
        }
    }

    /// Count of pending local notification requests registered for tasks.
    public func pendingNotificationCount() async -> Int {
        let requests = await notificationCenter.pendingNotificationRequests()
        return requests.filter {
            $0.identifier.hasPrefix(Self.notificationIDPrefix)
                || $0.identifier.hasPrefix(Self.legacyNotificationIDPrefix)
        }.count
    }

    /// Computes the next fire date for a schedule, or `nil` if none applies.
    ///
    /// One-off ("once") tasks fire at `scheduledDate` only if it's still in the
    /// future. Recurring tasks parse `scheduledTime` ("HH:mm") for today and, if
    /// that moment has already passed, roll forward by the cadence
    /// (day/week/month). `after` is injectable to keep the logic testable.
    public static func computeNextRun(
        schedule: String?,
        scheduledTime: String?,
        scheduledDate: Date?,
        after: Date = .now
    ) -> Date? {
        // No schedule: fall back to any explicit one-off date.
        guard let schedule else { return scheduledDate }

        // One-off: only valid while still in the future.
        if schedule == TaskSchedule.once.rawValue {
            guard let scheduledDate, scheduledDate > after else { return nil }
            return scheduledDate
        }

        // Recurring schedules need a valid "HH:mm" time-of-day.
        guard let scheduledTime else { return nil }
        let parts = scheduledTime.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        // Build today's occurrence at the requested time in the current timezone.
        var calendar = Calendar.current
        calendar.timeZone = .current
        var candidate = calendar.dateComponents([.year, .month, .day], from: after)
        candidate.hour = hour
        candidate.minute = minute
        candidate.second = 0
        guard var next = calendar.date(from: candidate) else { return nil }
        // If that time already passed today, advance by the cadence to the next
        // occurrence.
        if next <= after {
            switch schedule {
            case TaskSchedule.daily.rawValue:
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            case TaskSchedule.weekly.rawValue:
                next = calendar.date(byAdding: .day, value: 7, to: next) ?? next
            case TaskSchedule.monthly.rawValue:
                next = calendar.date(byAdding: .month, value: 1, to: next) ?? next
            default:
                return scheduledDate
            }
        }
        return next
    }

    /// Registers (replacing any existing) a one-shot calendar notification for a
    /// task at `fireDate`.
    ///
    /// Removes the prior request first so re-scheduling never double-fires, and
    /// stashes the task id in `userInfo` so the app can act on the tap.
    private func scheduleNotification(for task: ScheduledTask, fireDate: Date) async throws {
        // Replace any previously scheduled reminder for this task.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIDs(for: task.id))

        // Compose the notification content from the task.
        let content = UNMutableNotificationContent()
        content.title = task.name
        content.body = task.prompt ?? "Scheduled task is due."
        content.sound = .default
        content.userInfo = ["taskID": task.id]

        // Fire once at the exact fire date (down to the second).
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationID(for: task.id),
            content: content,
            trigger: trigger
        )
        do {
            try await notificationCenter.add(request)
        } catch {
            throw TaskSchedulerError.schedulingFailed(error.localizedDescription)
        }
    }

    /// Prefix for current notification identifiers (also excluded from iCloud defaults sync).
    public static let notificationIDPrefix = "anaiodyssey.task."
    /// Prefix used by pre-rename builds; still cancelled when a task is updated.
    public static let legacyNotificationIDPrefix = "odysseus.task."

    /// Stable, per-task notification identifier (prefixed so it's excluded from
    /// iCloud defaults sync and easy to target for removal).
    private func notificationID(for taskID: String) -> String {
        Self.notificationIDPrefix + taskID
    }

    private func notificationIDs(for taskID: String) -> [String] {
        [notificationID(for: taskID), Self.legacyNotificationIDPrefix + taskID]
    }
}

/// Environment key backing the optional `taskSchedulerService` value.
private struct TaskSchedulerServiceKey: EnvironmentKey {
    static let defaultValue: TaskSchedulerService? = nil
}

/// SwiftUI environment access to the shared `TaskSchedulerService`.
public extension EnvironmentValues {
    var taskSchedulerService: TaskSchedulerService? {
        get { self[TaskSchedulerServiceKey.self] }
        set { self[TaskSchedulerServiceKey.self] = newValue }
    }
}

/// When to show the notification permission prompt: when the user schedules a task or turns
/// reminders on in Settings, not over the first launch.
public enum NotificationPromptPolicy {
    public enum Moment: Equatable, Sendable {
        case launch(activeTasksWithNotifications: Int)
        case schedulingTask
        case settings
    }

    public static func shouldAsk(_ moment: Moment) -> Bool {
        switch moment {
        case .launch(let n): n > 0
        case .schedulingTask, .settings: true
        }
    }
}
