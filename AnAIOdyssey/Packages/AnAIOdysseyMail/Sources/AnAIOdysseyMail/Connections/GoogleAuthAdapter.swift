// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Google Auth adapter: one signed-in Google account as both an email and a calendar provider.
///
/// Holds the account-scoped OAuth client and maps Gmail / Calendar REST into the
/// shared `MailReaderServiceProtocol` and `CalendarProviderAdapter` seams so the
/// Email and Calendar tabs (and the agent) stay provider-agnostic.
@MainActor
public final class GoogleAuthAdapter: EmailProviderAdapter, CalendarProviderAdapter {
    public static let eventIDPrefix = "google-"

    public let account: MailAccount
    private let accountStore: MailAccountStore
    private let session: URLSession
    private let calendarCache: (any CalendarEventRepositoryProtocol)?

    public init(
        account: MailAccount,
        accountStore: MailAccountStore,
        session: URLSession = .shared,
        calendarCache: (any CalendarEventRepositoryProtocol)? = nil
    ) {
        self.account = account
        self.accountStore = accountStore
        self.session = session
        self.calendarCache = calendarCache
    }

    public var connectionID: String { Self.connectionID(for: account.id) }

    public static func connectionID(for accountID: String) -> String {
        "google:\(accountID)"
    }

    public var displayName: String { account.label }

    public var isAvailable: Bool { accountStore.isSignedIn(account) }

    public func makeMailReader() -> any MailReaderServiceProtocol {
        GmailMailReaderService(
            oauth: accountStore.oauthService(for: account),
            tokenStore: accountStore.tokenStore(for: account),
            accountID: account.id,
            accountLabel: account.label,
            session: session
        )
    }

    public func ownsEvent(id: String) -> Bool {
        id.hasPrefix(Self.eventIDPrefix)
    }

    public func listEvents(from start: Date, to end: Date) async throws -> [CalendarEventItem] {
        let api = GoogleCalendarAPIClient(oauth: accountStore.oauthService(for: account), session: session)
        let calendars = try await api.listCalendars()
        var items: [CalendarEventItem] = []
        for calendar in calendars {
            let events = try await api.listEvents(calendarID: calendar.id, from: start, to: end)
            for event in events {
                let item = Self.item(from: event, sourceID: connectionID)
                if let calendarCache {
                    _ = try calendarCache.upsertEvent(
                        id: item.id,
                        title: item.title,
                        startDate: item.startDate,
                        endDate: item.endDate,
                        calendarID: item.calendarID,
                        notes: item.notes,
                        location: item.location,
                        allDay: item.allDay,
                        status: "confirmed"
                    )
                }
                items.append(item)
            }
        }
        try calendarCache?.save()
        return items
    }

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String?,
        location: String?,
        allDay: Bool
    ) async throws -> CalendarEventItem {
        let api = GoogleCalendarAPIClient(oauth: accountStore.oauthService(for: account), session: session)
        let payload = try await api.insertEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes,
            location: location,
            allDay: allDay
        )
        let item = Self.item(from: payload, sourceID: connectionID)
        if let calendarCache {
            _ = try calendarCache.upsertEvent(
                id: item.id,
                title: item.title,
                startDate: item.startDate,
                endDate: item.endDate,
                calendarID: item.calendarID,
                notes: item.notes,
                location: item.location,
                allDay: item.allDay,
                status: "confirmed"
            )
            try calendarCache.save()
        }
        return item
    }

    public func deleteEvent(id: String) async throws {
        let googleID = String(id.dropFirst(Self.eventIDPrefix.count))
        guard !googleID.isEmpty else { return }
        let api = GoogleCalendarAPIClient(oauth: accountStore.oauthService(for: account), session: session)
        let calendarID: String
        if let cached = try calendarCache?.fetchEvent(id: id), !cached.calendarID.isEmpty {
            calendarID = cached.calendarID
        } else {
            calendarID = "primary"
        }
        try await api.deleteEvent(calendarID: calendarID, eventID: googleID)
        try calendarCache?.deleteEvent(id: id)
    }

    private static func item(from event: GoogleCalendarEventPayload, sourceID: String) -> CalendarEventItem {
        CalendarEventItem(
            id: "\(eventIDPrefix)\(event.id)",
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            calendarID: event.calendarID,
            notes: event.notes,
            location: event.location,
            allDay: event.allDay,
            sourceID: sourceID
        )
    }
}

#if os(macOS)
/// Local Apple Mail store as an email-only adapter (macOS).
public struct AppleMailEmailAdapter: EmailProviderAdapter {
    public static let connectionID = "apple-mail"

    public init() {}

    public var connectionID: String { Self.connectionID }
    public var displayName: String { "Apple Mail" }
    public var isAvailable: Bool { true }

    public func makeMailReader() -> any MailReaderServiceProtocol {
        MailReaderService()
    }
}
#endif
