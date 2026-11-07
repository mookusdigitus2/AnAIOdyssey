// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A local cache of a system (EventKit) calendar event — mirrors the Python
/// app's `CalendarEvent`.
///
/// `CalendarService` is the source of truth via EventKit; this record lets the
/// app display and query events offline (and lets agents reference them) without
/// hitting EventKit on every read. `id` matches the EventKit event identifier so
/// upserts stay idempotent.
@Model
public final class CalendarEventRecord {
    /// EventKit event identifier; the cache key used for idempotent upserts.
    public var id: String = ""
    /// Event title.
    public var title: String = ""
    /// Start/end of the event.
    public var startDate: Date = Date()
    public var endDate: Date = Date()
    /// Identifier of the owning system calendar.
    public var calendarID: String = ""
    /// Optional free-form notes and location.
    public var notes: String?
    public var location: String?
    /// Whether the event spans the whole day (no meaningful time component).
    public var allDay: Bool = false
    /// Lifecycle status (e.g. "confirmed"/"cancelled"); cancelled events are
    /// filtered out of range queries.
    public var status: String = "confirmed"

    /// Cache bookkeeping timestamps.
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Creates a cached event record; `id` defaults to a fresh UUID but callers
    /// normally pass the EventKit identifier so the cache stays in sync.
    public init(
        id: String = UUID().uuidString,
        title: String = "",
        startDate: Date,
        endDate: Date,
        calendarID: String,
        notes: String? = nil,
        location: String? = nil,
        allDay: Bool = false,
        status: String = "confirmed",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarID = calendarID
        self.notes = notes
        self.location = location
        self.allDay = allDay
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
