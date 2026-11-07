// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Settings controls for local notification permission and task reminders.
struct NotificationSettingsSection: View {
    @Environment(\.taskSchedulerService) private var taskScheduler
    @State private var authorizationState: NotificationAuthorizationState = .notDetermined
    @State private var pendingCount = 0
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Section("Notifications") {
            if taskScheduler == nil {
                Text("Task scheduler is unavailable. Restart the app and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Permission", value: authorizationLabel)
            if pendingCount > 0 {
                LabeledContent("Pending reminders", value: "\(pendingCount)")
            }
            Text("Scheduled tasks post local reminders when they are due. Grant permission so \(AppBranding.appName) can alert you and run task prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if authorizationState == .notDetermined {
                Button("Enable Notifications") {
                    Task { await requestAccess() }
                }
                .disabled(taskScheduler == nil)
            } else if authorizationState == .denied {
                Button("Open Notification Settings") {
                    openSystemNotificationSettings()
                }
            } else {
                Button("Refresh Reminders") {
                    Task { await refreshReminders() }
                }
                .disabled(taskScheduler == nil)
            }

            if let statusMessage {
                StatusMessage(kind: .success, text: statusMessage)
            }
            if let errorMessage {
                StatusMessage(kind: .error, text: errorMessage)
            }
        }
        .task {
            await reloadStatus()
        }
    }

    private var authorizationLabel: String {
        switch authorizationState {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        }
    }

    @MainActor
    private func reloadStatus() async {
        guard let taskScheduler else { return }
        authorizationState = await taskScheduler.authorizationState()
        pendingCount = await taskScheduler.pendingNotificationCount()
    }

    @MainActor
    private func requestAccess() async {
        guard let taskScheduler else { return }
        errorMessage = nil
        statusMessage = nil
        do {
            try await taskScheduler.requestNotificationAccessIfNeeded()
            try await taskScheduler.rescheduleAllActiveTasks()
            await reloadStatus()
            statusMessage = "Notifications enabled. Active task reminders were refreshed."
        } catch {
            await reloadStatus()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshReminders() async {
        guard let taskScheduler else { return }
        errorMessage = nil
        statusMessage = nil
        do {
            try await taskScheduler.rescheduleAllActiveTasks()
            await reloadStatus()
            statusMessage = "Pending reminders were refreshed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSystemNotificationSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        let bundleID = Bundle.main.bundleIdentifier ?? AppBranding.bundleIdentifier
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        #endif
    }
}
