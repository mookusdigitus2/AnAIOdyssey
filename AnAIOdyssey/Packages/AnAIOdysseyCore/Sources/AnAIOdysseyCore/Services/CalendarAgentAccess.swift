// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Dependencies for the agent's calendar tool: refresh system (EventKit) and
/// optional Google Calendar sync into the local cache before listing events.
@MainActor
public struct CalendarAgentAccess {
    /// Reads the user's system calendars via EventKit and mirrors into the cache.
    public let calendarService: CalendarService?
    /// When set, pulls Google Calendar events for the requested window into the cache.
    public let refreshGoogleCalendar: ((Date, Date) async throws -> Void)?

    public init(
        calendarService: CalendarService? = nil,
        refreshGoogleCalendar: ((Date, Date) async throws -> Void)? = nil
    ) {
        self.calendarService = calendarService
        self.refreshGoogleCalendar = refreshGoogleCalendar
    }

    /// Refreshes every configured calendar source for `[start, end]`.
    public func refresh(from start: Date, to end: Date) async -> [String] {
        var notes: [String] = []

        if let calendarService {
            do {
                _ = try await calendarService.listEvents(from: start, to: end)
            } catch CalendarServiceError.accessDenied {
                notes.append(
                    "System calendar access was denied. Grant Calendar permission in Settings → \(AppBranding.appName)."
                )
            } catch {
                notes.append("Could not read the system calendar: \(error.localizedDescription)")
            }
        }

        if let refreshGoogleCalendar {
            do {
                try await refreshGoogleCalendar(start, end)
            } catch {
                notes.append("Could not sync Google Calendar: \(error.localizedDescription)")
            }
        }

        return notes
    }
}
