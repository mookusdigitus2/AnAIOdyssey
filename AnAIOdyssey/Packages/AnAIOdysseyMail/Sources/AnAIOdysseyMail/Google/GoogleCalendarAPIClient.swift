// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// One entry from the user's Google calendar list (its id and display title).
struct GoogleCalendarListEntry: Sendable {
    let id: String
    let summary: String
}

/// A normalized Google Calendar event ready to be cached locally.
///
/// `allDay` distinguishes date-only events (which use midnight UTC boundaries) from
/// timed events parsed from RFC 3339 `dateTime` values.
struct GoogleCalendarEventPayload: Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarID: String
    let notes: String?
    let location: String?
    let allDay: Bool
}

/// Thin async client for the Google Calendar REST API (calendar list + events).
///
/// Authenticates every request with a fresh bearer token from `GoogleOAuthService` and
/// decodes the loosely-typed JSON responses into the structs above.
public final class GoogleCalendarAPIClient {
    private let oauth: GoogleOAuthService
    private let session: URLSession

    public init(oauth: GoogleOAuthService, session: URLSession = .shared) {
        self.oauth = oauth
        self.session = session
    }

    /// Fetches all calendars in the signed-in user's calendar list.
    func listCalendars() async throws -> [GoogleCalendarListEntry] {
        let object = try await requestJSON(path: "/calendar/v3/users/me/calendarList")
        // Decode each item, defaulting the display title to the id when absent.
        guard let items = object["items"] as? [[String: Any]] else {
            ConnectionDebug.log("Calendar", "calendar list contained no items array")
            return []
        }
        let parsed: [GoogleCalendarListEntry] = items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return GoogleCalendarListEntry(id: id, summary: item["summary"] as? String ?? id)
        }
        ConnectionDebug.log("Calendar", "calendars fetched raw=\(items.count) parsed=\(parsed.count)")
        return parsed
    }

    /// Fetches events for a calendar within a time window, expanded to single instances.
    ///
    /// Uses `singleEvents=true` so recurring events are returned as individual occurrences,
    /// ordered by start time and capped at 250 results.
    func listEvents(calendarID: String, from start: Date, to end: Date) async throws -> [GoogleCalendarEventPayload] {
        // Percent-encode the calendar id since it can contain characters like '@'.
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: Self.rfc3339(start)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339(end)),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        let object = try await requestJSON(url: components.url!)
        // Map raw event JSON into typed payloads, dropping any that fail to parse.
        guard let items = object["items"] as? [[String: Any]] else {
            ConnectionDebug.log("Calendar", "events fetched count=0")
            return []
        }
        let parsed: [GoogleCalendarEventPayload] = items.compactMap {
            parseEvent($0, calendarID: calendarID)
        }
        ConnectionDebug.log("Calendar", "events fetched raw=\(items.count) parsed=\(parsed.count)")
        return parsed
    }

    /// Creates an event on `calendarID` (default: the user's primary calendar).
    func insertEvent(
        calendarID: String = "primary",
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String?,
        location: String?,
        allDay: Bool
    ) async throws -> GoogleCalendarEventPayload {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        var body: [String: Any] = ["summary": title]
        if let notes { body["description"] = notes }
        if let location { body["location"] = location }
        if allDay {
            body["start"] = ["date": Self.dateOnlyFormatter.string(from: startDate)]
            body["end"] = ["date": Self.dateOnlyFormatter.string(from: endDate)]
        } else {
            body["start"] = ["dateTime": Self.rfc3339(startDate)]
            body["end"] = ["dateTime": Self.rfc3339(endDate)]
        }
        let object = try await GoogleAuthorizedJSONRequest.perform(oauth: oauth, session: session) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        }
        guard let payload = parseEvent(object, calendarID: calendarID) else {
            throw GoogleAPIError.invalidResponse
        }
        return payload
    }

    /// Deletes a Google Calendar event. `eventID` is the API id, not the `google-` cache key.
    func deleteEvent(calendarID: String, eventID: String) async throws {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)")!
        _ = try await GoogleAuthorizedJSONRequest.performAllowingEmpty(oauth: oauth, session: session) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    /// Convenience overload that resolves a relative API path against the Google host.
    private func requestJSON(path: String) async throws -> [String: Any] {
        try await requestJSON(url: URL(string: "https://www.googleapis.com\(path)")!)
    }

    /// Performs an authenticated GET and decodes the JSON object body.
    ///
    /// Attaches a fresh bearer token, retries once with a force-refreshed token on
    /// HTTP 401, maps a repeated 401 to `.unauthorized`, other non-2xx statuses to
    /// `.requestFailed` (with a truncated body), and non-object bodies to
    /// `.invalidResponse`.
    private func requestJSON(url: URL) async throws -> [String: Any] {
        try await GoogleAuthorizedJSONRequest.perform(oauth: oauth, session: session) { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    /// Converts a single raw Calendar event JSON object into a typed payload.
    ///
    /// Handles two shapes: all-day events carry a `date` (yyyy-MM-dd) and timed events
    /// carry an RFC 3339 `dateTime`. Returns `nil` if the id or required dates are missing.
    private func parseEvent(_ object: [String: Any], calendarID: String) -> GoogleCalendarEventPayload? {
        guard let id = object["id"] as? String else { return nil }
        let title = object["summary"] as? String ?? "(No title)"
        let start = object["start"] as? [String: Any] ?? [:]
        let end = object["end"] as? [String: Any] ?? [:]

        // All-day events use a plain `date`; parse both ends with the date-only formatter.
        if let date = start["date"] as? String {
            let formatter = Self.dateOnlyFormatter
            guard let startDate = formatter.date(from: date),
                  let endDateString = end["date"] as? String,
                  let endDate = formatter.date(from: endDateString) else {
                return nil
            }
            return GoogleCalendarEventPayload(
                id: id,
                title: title,
                startDate: startDate,
                endDate: endDate,
                calendarID: calendarID,
                notes: object["description"] as? String,
                location: object["location"] as? String,
                allDay: true
            )
        }

        // Otherwise it's a timed event; require both `dateTime` boundaries.
        guard let startDate = Self.parseDateTime(start),
              let endDate = Self.parseDateTime(end) else {
            return nil
        }

        return GoogleCalendarEventPayload(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarID: calendarID,
            notes: object["description"] as? String,
            location: object["location"] as? String,
            allDay: false
        )
    }

    /// Fixed-locale UTC formatter for Google's all-day `yyyy-MM-dd` dates.
    ///
    /// Uses `en_US_POSIX` and a Gregorian/UTC calendar so parsing is stable regardless
    /// of the device's locale or time zone.
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parses either a timed `dateTime` (ISO 8601) or an all-day `date` from a start/end object.
    private static func parseDateTime(_ component: [String: Any]) -> Date? {
        if let dateTime = component["dateTime"] as? String {
            return ISO8601DateFormatter().date(from: dateTime)
        }
        if let date = component["date"] as? String {
            return dateOnlyFormatter.date(from: date)
        }
        return nil
    }

    /// Formats a `Date` as an RFC 3339 string for the `timeMin`/`timeMax` query params.
    private static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Syncs Google Calendar events into the local calendar cache/repository.
///
/// Walks every calendar in the user's list, imports each event in the window, and
/// upserts it under a namespaced `google-<id>` key so re-syncs update rather than duplicate.
public final class GoogleCalendarSyncService {
    private let api: GoogleCalendarAPIClient
    private let cache: any CalendarEventRepositoryProtocol

    public init(api: GoogleCalendarAPIClient, cache: any CalendarEventRepositoryProtocol) {
        self.api = api
        self.cache = cache
    }

    /// Imports all events across all calendars within `[start, end]` and returns the count.
    ///
    /// Runs on the main actor because the repository is UI/state bound. Persists once at the
    /// end via `cache.save()`.
    @MainActor
    public func syncEvents(from start: Date, to end: Date) async throws -> Int {
        let calendars = try await api.listCalendars()
        var imported = 0
        // Pull events per calendar and upsert each into the local cache.
        for calendar in calendars {
            let events = try await api.listEvents(calendarID: calendar.id, from: start, to: end)
            for event in events {
                // Namespace the id with "google-" so syncs are idempotent (update, not insert).
                _ = try cache.upsertEvent(
                    id: "google-\(event.id)",
                    title: event.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    calendarID: event.calendarID,
                    notes: event.notes,
                    location: event.location,
                    allDay: event.allDay,
                    status: "confirmed"
                )
                imported += 1
            }
        }
        // Persist all upserts once after importing everything.
        try cache.save()
        return imported
    }
}
