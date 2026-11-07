// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Agent tool: tells the model today's date, the local time and the device's time zone.
///
/// Takes no input. Models otherwise only know the date from their training data, so
/// "today", "tomorrow" and "due in 3 days" would be guesses. The clock and zone are
/// injectable for tests; production reads them fresh on every call.
@MainActor
struct CurrentDateTool: AgentTool {
    let name = "current_date"
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(now: @escaping () -> Date = { Date() }, timeZone: @escaping () -> TimeZone = { TimeZone.current }) {
        self.now = now
        self.timeZone = timeZone
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        Self.report(for: now(), in: timeZone())
    }

    /// The tool's reply for `date` as seen in `zone`.
    nonisolated static func report(for date: Date, in zone: TimeZone) -> String {
        let offset = offsetString(seconds: zone.secondsFromGMT(for: date))
        return """
        Today is \(formatted(date, "EEEE, MMMM d, yyyy", zone)).
        Local time: \(formatted(date, "h:mm a", zone))
        Time zone: \(zone.identifier) (UTC\(offset))
        ISO 8601: \(formatted(date, "yyyy-MM-dd'T'HH:mm:ss", zone))\(offset)
        """
    }

    private nonisolated static func formatted(_ date: Date, _ format: String, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Signed hours and minutes east of UTC, e.g. "-07:00" or "+05:30".
    private nonisolated static func offsetString(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let totalMinutes = abs(seconds) / 60
        return sign + String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
