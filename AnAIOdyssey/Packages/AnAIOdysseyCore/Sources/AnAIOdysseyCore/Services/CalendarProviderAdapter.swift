// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Adapter for one calendar source (EventKit, Google Calendar, future providers).
///
/// `CalendarService` owns the EventKit implementation and merges any extra adapters
/// registered by the app (typically Google accounts from `WorkspaceConnectionManager`).
@MainActor
public protocol CalendarProviderAdapter: AnyObject {
    /// Stable id for the connection this adapter serves.
    var connectionID: String { get }
    /// User-facing name (account email, "On This Device", …).
    var displayName: String { get }
    /// Whether this adapter currently has credentials / permission to run.
    var isAvailable: Bool { get }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarEventItem]
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String?,
        location: String?,
        allDay: Bool
    ) async throws -> CalendarEventItem
    func deleteEvent(id: String) async throws
    /// True when `id` belongs to this adapter (used to route deletes).
    func ownsEvent(id: String) -> Bool
}

extension CalendarProviderAdapter {
    public func ownsEvent(id: String) -> Bool {
        id.hasPrefix("\(connectionID)|")
    }
}
