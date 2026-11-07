// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import EventKit
import Foundation
import SwiftUI

/// Lightweight, `Sendable` snapshot of a system calendar, decoupling the UI from
/// EventKit's `EKCalendar`.
public struct CalendarSummary: Identifiable, Sendable, Equatable {
    /// EventKit calendar identifier.
    public let id: String
    /// Display name of the calendar.
    public let title: String
    /// Calendar's color as a "#RRGGBB" hex string, if available.
    public let colorHex: String?

    public init(id: String, title: String, colorHex: String?) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}

/// Connection id used for events that came from the on-device EventKit store.
public let eventKitCalendarConnectionID = "eventkit"

/// Lightweight, `Sendable` value type representing a calendar event, returned to
/// the UI instead of EventKit's reference-type `EKEvent`.
public struct CalendarEventItem: Identifiable, Sendable, Equatable {
    /// Event identifier (EventKit id, or a provider-namespaced id).
    public let id: String
    /// Event title.
    public let title: String
    /// Start/end of the event.
    public let startDate: Date
    public let endDate: Date
    /// Identifier of the owning calendar.
    public let calendarID: String
    /// Optional notes and location.
    public let notes: String?
    public let location: String?
    /// Whether the event is all-day.
    public let allDay: Bool
    /// Connection that produced this event (`eventkit`, `google:<accountID>`, …).
    public let sourceID: String

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarID: String,
        notes: String?,
        location: String?,
        allDay: Bool,
        sourceID: String = eventKitCalendarConnectionID
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarID = calendarID
        self.notes = notes
        self.location = location
        self.allDay = allDay
        self.sourceID = sourceID
    }
}

/// Errors thrown by `CalendarService`.
public enum CalendarServiceError: Error, LocalizedError {
    /// The user denied/restricted calendar access.
    case accessDenied
    /// No writable calendar was available to create an event in.
    case calendarNotFound
    /// No event matched the given identifier.
    case eventNotFound(String)
    /// EventKit failed to persist a change; carries the underlying reason.
    case saveFailed(String)

    /// User-facing description for surfacing in alerts.
    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Calendar access was denied."
        case .calendarNotFound:
            "No writable calendar is available."
        case .eventNotFound(let id):
            "Calendar event '\(id)' was not found."
        case .saveFailed(let message):
            "Failed to save calendar event: \(message)"
        }
    }
}

/// Reads and writes calendars through EventKit plus any registered provider adapters.
///
/// EventKit covers on-device calendars. Extra adapters (Google Calendar via the
/// connection manager, future IMAP-like providers) are merged into the same
/// event list so iOS/iPadOS can show Google events without relying on EventKit
/// having the account. Every fetch/create also upserts into the
/// `CalendarEventRepositoryProtocol` cache so events are available offline.
/// `@MainActor` because it coordinates the main-actor-bound cache.
@MainActor
public final class CalendarService {
    /// The system EventKit store.
    private let eventStore = EKEventStore()
    /// Local mirror of fetched/created events.
    private let cache: any CalendarEventRepositoryProtocol
    /// Extra calendar sources (Google accounts, …) owned by the connection manager.
    private var extraProviders: [any CalendarProviderAdapter] = []

    /// Injects the cache repository.
    public init(cache: any CalendarEventRepositoryProtocol) {
        self.cache = cache
    }

    /// Replaces the extra calendar adapters merged into list/create/delete.
    public func setProviders(_ providers: [any CalendarProviderAdapter]) {
        extraProviders = providers
    }

    /// Ensures calendar access is granted, prompting once if undetermined.
    ///
    /// Accepts authorized/full/write-only states; throws `accessDenied` for
    /// denied/restricted so callers can stop before hitting EventKit.
    public func requestAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            // Already permitted.
            return
        case .notDetermined:
            // Prompt for access (full access on both platforms).
            #if os(macOS)
            let granted = try await eventStore.requestFullAccessToEvents()
            #else
            let granted = try await eventStore.requestFullAccessToEvents()
            #endif
            guard granted else { throw CalendarServiceError.accessDenied }
        default:
            // Denied/restricted.
            throw CalendarServiceError.accessDenied
        }
    }

    /// Returns summaries of all event calendars available to the app.
    public func listCalendars() throws -> [CalendarSummary] {
        eventStore.calendars(for: .event).map { calendar in
            CalendarSummary(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                colorHex: calendar.cgColor?.hexString
            )
        }
    }

    /// Fetches events overlapping `[start, end]` from EventKit and every extra
    /// provider, refreshes the local cache, and returns them sorted by start time.
    ///
    /// EventKit permission failures do not fail the call when a Google (or other)
    /// adapter is available — that's the iOS path when the user connected Gmail
    /// without granting system Calendar access.
    public func listEvents(from start: Date, to end: Date) async throws -> [CalendarEventItem] {
        var combined: [CalendarEventItem] = []
        var eventKitError: Error?

        do {
            combined.append(contentsOf: try await listEventKitEvents(from: start, to: end))
        } catch {
            eventKitError = error
        }

        for provider in extraProviders where provider.isAvailable {
            do {
                combined.append(contentsOf: try await provider.listEvents(from: start, to: end))
            } catch {
                if combined.isEmpty && eventKitError == nil {
                    eventKitError = error
                }
            }
        }

        if combined.isEmpty, let eventKitError {
            throw eventKitError
        }

        var seen = Set<String>()
        return combined
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.startDate < $1.startDate }
    }

    /// EventKit-only fetch used by `listEvents` and the cache mirror.
    private func listEventKitEvents(from start: Date, to end: Date) async throws -> [CalendarEventItem] {
        try await requestAccessIfNeeded()
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        for event in events {
            let eventID = event.eventIdentifier ?? UUID().uuidString
            try cache.upsertEvent(
                id: eventID,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                calendarID: event.calendar.calendarIdentifier,
                notes: event.notes,
                location: event.location,
                allDay: event.isAllDay,
                status: "confirmed"
            )
        }

        return events.compactMap { event in
            guard let id = event.eventIdentifier else { return nil }
            return CalendarEventItem(
                id: id,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                calendarID: event.calendar.calendarIdentifier,
                notes: event.notes,
                location: event.location,
                allDay: event.isAllDay,
                sourceID: eventKitCalendarConnectionID
            )
        }
    }

    /// Creates an event in the chosen (or default) calendar, mirrors it into the
    /// cache, and returns it as a value type.
    ///
    /// Resolves the target calendar from `calendarID`, falling back to the
    /// system default; throws `calendarNotFound` if neither is available and
    /// `saveFailed` if EventKit rejects the write.
    @discardableResult
    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        location: String? = nil,
        allDay: Bool = false,
        calendarID: String? = nil
    ) async throws -> CalendarEventItem {
        // Prefer EventKit when the user has granted access; otherwise create on
        // the first available extra provider (Google on iOS).
        if extraProviders.contains(where: { $0.isAvailable }) {
            do {
                try await requestAccessIfNeeded()
            } catch {
                return try await createEventOnExtraProvider(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    notes: notes,
                    location: location,
                    allDay: allDay
                )
            }
        } else {
            try await requestAccessIfNeeded()
        }

        // Pick the requested calendar, else the system default for new events.
        let calendar: EKCalendar
        if let calendarID,
           let selected = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarID }) {
            calendar = selected
        } else if let defaultCalendar = eventStore.defaultCalendarForNewEvents {
            calendar = defaultCalendar
        } else if extraProviders.contains(where: { $0.isAvailable }) {
            return try await createEventOnExtraProvider(
                title: title,
                startDate: startDate,
                endDate: endDate,
                notes: notes,
                location: location,
                allDay: allDay
            )
        } else {
            throw CalendarServiceError.calendarNotFound
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.isAllDay = allDay

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            throw CalendarServiceError.saveFailed(error.localizedDescription)
        }

        let eventID = event.eventIdentifier ?? UUID().uuidString
        try cache.upsertEvent(
            id: eventID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarID: calendar.calendarIdentifier,
            notes: notes,
            location: location,
            allDay: allDay,
            status: "confirmed"
        )

        return CalendarEventItem(
            id: eventID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarID: calendar.calendarIdentifier,
            notes: notes,
            location: location,
            allDay: allDay,
            sourceID: eventKitCalendarConnectionID
        )
    }

    private func createEventOnExtraProvider(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String?,
        location: String?,
        allDay: Bool
    ) async throws -> CalendarEventItem {
        guard let provider = extraProviders.first(where: { $0.isAvailable }) else {
            throw CalendarServiceError.calendarNotFound
        }
        return try await provider.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes,
            location: location,
            allDay: allDay
        )
    }

    /// Deletes an event from both EventKit and the local cache; throws
    /// `eventNotFound` if no such event exists.
    public func deleteEvent(id: String) async throws {
        if let provider = extraProviders.first(where: { $0.ownsEvent(id: id) && $0.isAvailable }) {
            try await provider.deleteEvent(id: id)
            try? cache.deleteEvent(id: id)
            return
        }
        try await requestAccessIfNeeded()
        guard let event = eventStore.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound(id)
        }
        try eventStore.remove(event, span: .thisEvent)
        try cache.deleteEvent(id: id)
    }

    /// Reads events from the local cache only (no EventKit access), e.g. for
    /// offline display.
    public func cachedEvents(from start: Date, to end: Date) throws -> [CalendarEventRecord] {
        try cache.listEvents(from: start, to: end)
    }
}

/// Environment key backing the optional `calendarService` value.
private struct CalendarServiceKey: EnvironmentKey {
    static let defaultValue: CalendarService? = nil
}

/// SwiftUI environment access to the shared `CalendarService`.
public extension EnvironmentValues {
    var calendarService: CalendarService? {
        get { self[CalendarServiceKey.self] }
        set { self[CalendarServiceKey.self] = newValue }
    }
}

/// Formats a `CGColor` as an "#RRGGBB" hex string for surfacing calendar colors.
private extension CGColor {
    /// Hex representation built from the first three (RGB) components, or `nil`
    /// if the color doesn't expose at least three components.
    var hexString: String? {
        guard let components = components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
