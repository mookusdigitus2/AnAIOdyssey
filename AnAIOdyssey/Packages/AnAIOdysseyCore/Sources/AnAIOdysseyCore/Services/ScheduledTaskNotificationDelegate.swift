// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import UserNotifications

/// Handles scheduled-task notification delivery and tap actions.
public final class ScheduledTaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public typealias TaskRunner = @MainActor (ScheduledTask) async -> Void

    private let scheduler: TaskSchedulerService
    private let onExecuteTask: TaskRunner?

    public init(scheduler: TaskSchedulerService, onExecuteTask: TaskRunner? = nil) {
        self.scheduler = scheduler
        self.onExecuteTask = onExecuteTask
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await handleOnMainActor(notification: notification)
        #if os(iOS)
        return [.banner, .list, .sound, .badge]
        #else
        return [.banner, .sound, .badge]
        #endif
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handleOnMainActor(notification: response.notification)
    }

    @MainActor
    private func handleOnMainActor(notification: UNNotification) async {
        guard let taskID = notification.request.content.userInfo["taskID"] as? String else { return }
        do {
            try await scheduler.handleTaskFired(id: taskID)
            if let task = try scheduler.fetchTask(id: taskID), let onExecuteTask {
                await onExecuteTask(task)
            }
        } catch {
            // Best-effort; scheduling state is still advanced when possible.
        }
    }
}
