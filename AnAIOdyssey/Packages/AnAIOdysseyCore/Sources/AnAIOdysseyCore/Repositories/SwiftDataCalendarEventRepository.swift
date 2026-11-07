// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `CalendarEventRepositoryProtocol`, the
/// local cache for EventKit events.
@MainActor
public final class SwiftDataCalendarEventRepository: CalendarEventRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func upsertEvent(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarID: String,
        notes: String?,
        location: String?,
        allDay: Bool,
        status: String
    ) throws -> CalendarEventRecord {
        // Upsert keyed by the EventKit id: update the cached row in place if it
        // already exists, otherwise insert a fresh one. This keeps the cache
        // idempotent as `CalendarService` re-syncs overlapping date ranges.
        if let existing = try fetchEvent(id: id) {
            existing.title = title
            existing.startDate = startDate
            existing.endDate = endDate
            existing.calendarID = calendarID
            existing.notes = notes
            existing.location = location
            existing.allDay = allDay
            existing.status = status
            existing.updatedAt = .now
            try save()
            return existing
        }

        let event = CalendarEventRecord(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarID: calendarID,
            notes: notes,
            location: location,
            allDay: allDay,
            status: status
        )
        context.insert(event)
        try save()
        return event
    }

    public func fetchEvent(id: String) throws -> CalendarEventRecord? {
        let descriptor = FetchDescriptor<CalendarEventRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listEvents(from start: Date, to end: Date) throws -> [CalendarEventRecord] {
        // Return events that overlap the window (not just those fully inside it)
        // and aren't cancelled, ordered chronologically by start.
        let descriptor = FetchDescriptor<CalendarEventRecord>(
            predicate: #Predicate { event in
                event.startDate < end && event.endDate > start && event.status != "cancelled"
            },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    public func deleteEvent(id: String) throws {
        guard let event = try fetchEvent(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(event)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
