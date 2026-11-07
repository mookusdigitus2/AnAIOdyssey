// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SQLite3
import SwiftUI

/// FTS5 sidecar index for unified search (derived data, rebuilt per device).
public final class SearchIndexStore {
    private var db: OpaquePointer?

    public init(databaseURL: URL) throws {
        var pointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &pointer) != SQLITE_OK {
            throw VectorIndexError.openFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        db = pointer
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
                kind,
                entity_id UNINDEXED,
                title,
                body,
                tokenize = 'unicode61'
            );
            """)
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    public func upsert(kind: String, entityID: String, title: String, body: String) throws {
        try delete(kind: kind, entityID: entityID)
        let sql = "INSERT INTO search_index(kind, entity_id, title, body) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, entityID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, body, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    public func delete(kind: String, entityID: String) throws {
        let sql = "DELETE FROM search_index WHERE kind = ? AND entity_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, entityID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    /// Clears the whole index (used before a full rebuild).
    public func removeAll() throws {
        try exec("DELETE FROM search_index;")
    }

    /// Number of rows in the FTS index.
    public func count() throws -> Int {
        let sql = "SELECT COUNT(*) FROM search_index;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    public func search(query: String, limit: Int) throws -> [(kind: String, entityID: String, title: String, snippet: String)] {
        let sql = """
        SELECT kind, entity_id, title, snippet(search_index, 3, '<b>', '</b>', '…', 12)
        FROM search_index
        WHERE search_index MATCH ?
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [(String, String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(statement, 0))
            let entityID = String(cString: sqlite3_column_text(statement, 1))
            let title = String(cString: sqlite3_column_text(statement, 2))
            let snippet = String(cString: sqlite3_column_text(statement, 3))
            results.append((kind, entityID, title, snippet))
        }
        return results
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw VectorIndexError.execFailed(message)
        }
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct SearchIndexStoreKey: EnvironmentKey {
    static let defaultValue: SearchIndexStore? = nil
}

public extension EnvironmentValues {
    var searchIndexStore: SearchIndexStore? {
        get { self[SearchIndexStoreKey.self] }
        set { self[SearchIndexStoreKey.self] = newValue }
    }
}
