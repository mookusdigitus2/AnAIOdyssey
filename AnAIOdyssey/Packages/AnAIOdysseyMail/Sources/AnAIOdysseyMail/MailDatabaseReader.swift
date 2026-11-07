// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SQLite3

/// Read-only SQLite accessor for Apple Mail's "Envelope Index" database.
///
/// Opens the database in immutable, read-only mode and exposes typed queries for
/// mailboxes and message summaries. Apple's schema for the `summaries` table varies
/// across macOS versions, so the reader detects the join style up front and adapts its
/// SQL accordingly. The class owns the underlying `sqlite3` handle for its lifetime and
/// closes it on `deinit`.
public final class MailDatabaseReader {
    /// How the `summaries` table relates to `messages` in this database's schema.
    ///
    /// Older/newer Mail versions differ: the message row may point at a summary, the
    /// summary may point back at the message, or summaries may be absent entirely.
    private enum SummariesJoinStyle {
        case messageReferencesSummary
        case summaryReferencesMessage
        case unavailable
    }

    private var db: OpaquePointer?
    private let summariesJoinStyle: SummariesJoinStyle

    /// Opens the Envelope Index read-only and immutable, then probes its schema.
    ///
    /// Uses `mode=ro&immutable=1` so we never lock or modify Mail's live database. A
    /// SQLite "authorization" failure is mapped to `.permissionDenied` (typically a
    /// missing Full Disk Access grant); other failures become `.databaseOpenFailed`.
    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        // Open immutably/read-only so we coexist safely with the running Mail.app.
        let uri = "file:\(databaseURL.path)?mode=ro&immutable=1"
        let result = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let handle else {
            // Capture the error message, then distinguish a permission problem from
            // any other open failure before closing the half-open handle.
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            if message.localizedCaseInsensitiveContains("authorization") {
                throw MailReaderError.permissionDenied
            }
            throw MailReaderError.databaseOpenFailed(message)
        }
        db = handle
        // Detect the summaries-join schema variant once, up front, for later queries.
        summariesJoinStyle = Self.detectSummariesJoinStyle(db: handle)
    }

    /// Closes the SQLite handle when the reader is deallocated.
    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Returns all mailboxes with their URLs and total/unread counts, sorted by URL.
    public func listMailboxes() throws -> [MailMailbox] {
        let sql = """
        SELECT ROWID, url, total_count, unread_count
        FROM mailboxes
        ORDER BY url COLLATE NOCASE
        """
        // Map each result row into a typed MailMailbox value.
        return try query(sql: sql) { statement in
            let id = sqlite3_column_int64(statement, 0)
            let url = columnText(statement, index: 1) ?? "Unknown"
            let total = Int(sqlite3_column_int(statement, 2))
            let unread = Int(sqlite3_column_int(statement, 3))
            return MailMailbox(id: id, url: url, totalCount: total, unreadCount: unread)
        }
    }

    /// Returns recent message summaries, newest first, optionally filtered by mailbox.
    ///
    /// Joins subjects, sender addresses, mailbox URLs, and (when available) the cached
    /// summary snippet. `mailboxID` scopes results to one mailbox; `limit` caps the count.
    public func listMessages(mailboxID: Int64? = nil, limit: Int = 100) throws -> [MailMessageSummary] {
        // Build the base join. The summaries select/join fragments adapt to the schema.
        var sql = """
        SELECT
            m.ROWID,
            m.message_id,
            COALESCE(s.subject, '(no subject)'),
            COALESCE(a.address, 'unknown'),
            a.comment,
            m.date_received,
            m.read,
            m.flagged,
            mb.url,
            \(summariesSelectSQL)
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        \(summariesJoinSQL)
        """
        // Optionally constrain to a single mailbox.
        if mailboxID != nil {
            sql += " WHERE m.mailbox = ?"
        }
        // Always return newest-first and bound the result size.
        sql += " ORDER BY m.date_received DESC LIMIT ?"

        return try query(sql: sql, bind: { statement in
            // Bind the optional mailbox filter first (when present), then the limit.
            var index: Int32 = 1
            if let mailboxID {
                sqlite3_bind_int64(statement, index, mailboxID)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit))
        }) { statement in
            // Decode each column into a typed MailMessageSummary.
            let rowID = sqlite3_column_int64(statement, 0)
            let messageID = sqlite3_column_int64(statement, 1)
            let subject = columnText(statement, index: 2) ?? "(no subject)"
            let senderAddress = columnText(statement, index: 3) ?? "unknown"
            let senderName = columnText(statement, index: 4)
            // Mail stores dates as seconds since the reference date; preserve NULL.
            let dateReceived = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5))
            let isRead = sqlite3_column_int(statement, 6) != 0
            let isFlagged = sqlite3_column_int(statement, 7) != 0
            let mailboxURL = columnText(statement, index: 8)
            let snippet = columnText(statement, index: 9)

            return MailMessageSummary(
                id: rowID,
                messageID: messageID,
                subject: subject,
                senderAddress: senderAddress,
                senderName: senderName,
                dateReceived: dateReceived,
                snippet: snippet,
                isRead: isRead,
                isFlagged: isFlagged,
                mailboxURL: mailboxURL
            )
        }
    }

    /// Loads the summary for a single message by row id, or `nil` if it doesn't exist.
    ///
    /// Same column shape as `listMessages` but constrained to one row; used before
    /// fetching the full body so we can resolve the `.emlx` message id.
    public func messageSummary(id: Int64) throws -> MailMessageSummary? {
        let sql = """
        SELECT
            m.ROWID,
            m.message_id,
            COALESCE(s.subject, '(no subject)'),
            COALESCE(a.address, 'unknown'),
            a.comment,
            m.date_received,
            m.read,
            m.flagged,
            mb.url,
            \(summariesSelectSQL)
        FROM messages m
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
        \(summariesJoinSQL)
        WHERE m.ROWID = ?
        LIMIT 1
        """

        return try query(sql: sql, bind: { statement in
            // Bind the requested row id.
            sqlite3_bind_int64(statement, 1, id)
        }) { statement in
            // Decode the single matching row into a typed MailMessageSummary.
            let rowID = sqlite3_column_int64(statement, 0)
            let messageID = sqlite3_column_int64(statement, 1)
            let subject = columnText(statement, index: 2) ?? "(no subject)"
            let senderAddress = columnText(statement, index: 3) ?? "unknown"
            let senderName = columnText(statement, index: 4)
            // Mail stores dates as seconds since the reference date; preserve NULL.
            let dateReceived = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5))
            let isRead = sqlite3_column_int(statement, 6) != 0
            let isFlagged = sqlite3_column_int(statement, 7) != 0
            let mailboxURL = columnText(statement, index: 8)
            let snippet = columnText(statement, index: 9)

            return MailMessageSummary(
                id: rowID,
                messageID: messageID,
                subject: subject,
                senderAddress: senderAddress,
                senderName: senderName,
                dateReceived: dateReceived,
                snippet: snippet,
                isRead: isRead,
                isFlagged: isFlagged,
                mailboxURL: mailboxURL
            )
        }.first
    }

    /// Generic prepared-statement runner: prepares, optionally binds, steps, and maps rows.
    ///
    /// Centralizes the SQLite boilerplate so the public queries only supply SQL, a bind
    /// closure, and a per-row mapping. Finalizes the statement via `defer` and converts
    /// any step/prepare failure into `.queryFailed`.
    private func query<T>(
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        // The handle must still be open (it can't be nil after a successful init).
        guard let db else {
            throw MailReaderError.databaseOpenFailed("Database handle missing")
        }

        // Compile the SQL into a prepared statement.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        // Let the caller bind any parameter placeholders.
        bind?(statement)

        // Step through every row, mapping each, until the result set is exhausted.
        var rows: [T] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                rows.append(map(statement))
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw MailReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }

    /// Safely reads a TEXT column as a Swift `String`, returning `nil` for SQL NULL.
    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    /// The `summaries` JOIN clause appropriate for the detected schema (empty if absent).
    private var summariesJoinSQL: String {
        switch summariesJoinStyle {
        case .messageReferencesSummary:
            "LEFT JOIN summaries sm ON m.summary = sm.ROWID"
        case .summaryReferencesMessage:
            "LEFT JOIN summaries sm ON sm.message = m.ROWID"
        case .unavailable:
            ""
        }
    }

    /// The summary snippet SELECT expression for the detected schema (NULL if absent).
    private var summariesSelectSQL: String {
        switch summariesJoinStyle {
        case .messageReferencesSummary, .summaryReferencesMessage:
            "sm.summary"
        case .unavailable:
            "NULL"
        }
    }

    /// Inspects the live schema to decide how `summaries` joins to `messages`.
    ///
    /// Reads the column sets of both tables and infers the relationship direction,
    /// falling back to `.unavailable` when there's no usable `summary` column to join.
    private static func detectSummariesJoinStyle(db: OpaquePointer) -> SummariesJoinStyle {
        let summaryColumns = tableColumns(db: db, table: "summaries")
        let messageColumns = tableColumns(db: db, table: "messages")

        // No summary text column means summaries can't contribute a snippet.
        guard summaryColumns.contains("summary") else {
            return .unavailable
        }

        // Newer schema: each message row references its summary by ROWID.
        if messageColumns.contains("summary"), !summaryColumns.contains("message") {
            return .messageReferencesSummary
        }

        // Alternate schema: each summary row references its message by ROWID.
        if summaryColumns.contains("message") {
            return .summaryReferencesMessage
        }

        return .unavailable
    }

    /// Returns the set of column names for `table` via `PRAGMA table_info`.
    ///
    /// Used by schema detection; returns an empty set if the pragma can't be prepared.
    private static func tableColumns(db: OpaquePointer, table: String) -> Set<String> {
        var columns = Set<String>()
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return columns
        }
        defer { sqlite3_finalize(statement) }

        // Column 1 of table_info is the column name; collect them all.
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }
}
