// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI

/// Stable identifiers for the app's auxiliary (pop-out) windows.
///
/// Shared between the host app (which declares the matching `WindowGroup`s) and
/// the feature views (whose toolbar buttons call `openWindow(id:)`).
public enum AppWindowID {
    public static let email = "anaiodyssey.window.email"
    public static let tasks = "anaiodyssey.window.tasks"
    public static let calendar = "anaiodyssey.window.calendar"
}

/// A toolbar button that pops the current feature out into its own window.
///
/// No-ops gracefully if the matching `WindowGroup` isn't declared. Hidden inside
/// the pop-out window itself (there's nothing to pop out to).
public struct PopOutWindowButton: View {
    private let windowID: String
    @Environment(\.openWindow) private var openWindow
    /// True when already rendered inside the standalone window, so we hide it.
    @Environment(\.isPoppedOutWindow) private var isPoppedOut

    public init(windowID: String) {
        self.windowID = windowID
    }

    public var body: some View {
        if !isPoppedOut {
            Button {
                openWindow(id: windowID)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.on.rectangle")
            }
            .help("Open in a separate window")
            .accessibilityIdentifier("pop-out-\(windowID)")
        }
    }
}

/// Standalone window hosting the Email workspace (pop-out scene root).
public struct EmailWindowScene: View {
    public init() {}
    public var body: some View {
        EmailView().environment(\.isPoppedOutWindow, true)
    }
}

/// Standalone window hosting the Tasks workspace (pop-out scene root).
public struct TasksWindowScene: View {
    public init() {}
    public var body: some View {
        TasksView().environment(\.isPoppedOutWindow, true)
    }
}

/// Standalone window hosting the Calendar workspace (pop-out scene root).
public struct CalendarWindowScene: View {
    public init() {}
    public var body: some View {
        AppCalendarView().environment(\.isPoppedOutWindow, true)
    }
}

/// Environment flag marking views rendered inside a standalone pop-out window,
/// so shared chrome (like the pop-out button) can hide itself there.
private struct IsPoppedOutWindowKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isPoppedOutWindow: Bool {
        get { self[IsPoppedOutWindowKey.self] }
        set { self[IsPoppedOutWindowKey.self] = newValue }
    }
}
