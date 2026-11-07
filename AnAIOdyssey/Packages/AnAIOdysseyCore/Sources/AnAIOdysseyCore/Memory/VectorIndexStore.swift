// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SQLite3

/// One result row from a vector search: which memory matched and how strongly.
public struct VectorSearchHit: Sendable, Equatable {
    /// ID of the matching `Memory` (use it to load the full record).
    public let memoryID: String
    /// The matched memory's text, cached in the index for convenience.
    public let text: String
    /// Cosine-similarity score; higher is more relevant.
    public let score: Float

    public init(memoryID: String, text: String, score: Float) {
        self.memoryID = memoryID
        self.text = text
        self.score = score
    }
}

/// Errors thrown by `VectorIndexStore`, mapped from SQLite failure points.
public enum VectorIndexError: Error, LocalizedError {
    /// The database file could not be opened.
    case openFailed(String)
    /// A write/exec statement failed.
    case execFailed(String)
    /// A statement could not be prepared (usually a query).
    case prepareFailed(String)

    /// User-facing description carrying the underlying SQLite message.
    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open vector index: \(message)"
        case .execFailed(let message): "Vector index write failed: \(message)"
        case .prepareFailed(let message): "Vector index query failed: \(message)"
        }
    }
}

/// SQLite-backed vector index for semantic memory search.
///
/// Stores each memory's embedding as a BLOB keyed by `memory_id`. Search is a
/// brute-force linear scan scored with cosine similarity — simple and exact,
/// which is appropriate for the modest number of memories a single user
/// accumulates. The canonical memory text/metadata lives in SwiftData; this is
/// purely the similarity index.
public final class VectorIndexStore {
    /// Handle to the open SQLite database (`nil` once closed).
    private var db: OpaquePointer?

    /// Opens (or creates) the index at `databaseURL` and ensures the schema
    /// exists. Throws `VectorIndexError.openFailed` if the file can't be opened.
    public init(databaseURL: URL) throws {
        var pointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &pointer) != SQLITE_OK {
            throw VectorIndexError.openFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        db = pointer
        // Idempotently create the backing table; `memory_id` is unique so upserts
        // can key off it.
        try exec(
            """
            CREATE TABLE IF NOT EXISTS memory_vectors (
                id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL UNIQUE,
                text TEXT NOT NULL,
                embedding BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS index_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
    }

    private enum MetadataKey {
        static let embeddingModel = "embedding_model_id"
        static let embeddingDimension = "embedding_dimension"
    }

    /// Stored embedding model metadata, if any.
    public func storedEmbeddingMetadata() -> (modelID: String, dimension: Int)? {
        guard
            let modelID = metadataValue(for: MetadataKey.embeddingModel),
            let dimensionString = metadataValue(for: MetadataKey.embeddingDimension),
            let dimension = Int(dimensionString)
        else {
            return nil
        }
        return (modelID, dimension)
    }

    /// Records which embedding model/dimension the index was built with.
    public func setEmbeddingMetadata(modelID: String, dimension: Int) throws {
        try setMetadataValue(modelID, for: MetadataKey.embeddingModel)
        try setMetadataValue(String(dimension), for: MetadataKey.embeddingDimension)
    }

    /// Drops every indexed vector (metadata is preserved until overwritten).
    public func clearAllVectors() throws {
        try exec("DELETE FROM memory_vectors;")
    }

    /// Closes the SQLite handle when the store is deallocated.
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    /// Inserts or updates the embedding/text for a memory.
    ///
    /// Uses an `ON CONFLICT(memory_id)` upsert so re-indexing a memory replaces
    /// its row rather than duplicating it.
    public func upsert(memoryID: String, text: String, embedding: [Float]) throws {
        let sql = """
        INSERT INTO memory_vectors (id, memory_id, text, embedding)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(memory_id) DO UPDATE SET
            text = excluded.text,
            embedding = excluded.embedding;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        // Bind the row values; the embedding is serialized to its raw byte blob.
        // SQLITE_TRANSIENT tells SQLite to copy the buffers (they don't outlive
        // this call).
        let rowID = memoryID
        sqlite3_bind_text(statement, 1, rowID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, memoryID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, text, -1, SQLITE_TRANSIENT)
        let data = embedding.embeddingData
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, 4, rawBuffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    /// Removes a memory's row from the index (no-op if it isn't present).
    public func delete(memoryID: String) throws {
        let sql = "DELETE FROM memory_vectors WHERE memory_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, memoryID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    /// Returns the `topK` memories most similar to `queryEmbedding`, best first.
    ///
    /// Scans every stored vector, scores it by cosine similarity, then sorts and
    /// truncates. Exact (not approximate) — fine for per-user index sizes.
    public func search(queryEmbedding: [Float], topK: Int) throws -> [VectorSearchHit] {
        let sql = "SELECT memory_id, text, embedding FROM memory_vectors;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        // Score every row against the query vector.
        var hits: [VectorSearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // Skip rows missing their text columns rather than failing the search.
            guard
                let memoryIDCString = sqlite3_column_text(statement, 0),
                let textCString = sqlite3_column_text(statement, 1)
            else {
                continue
            }
            let memoryID = String(cString: memoryIDCString)
            let text = String(cString: textCString)
            // Decode the stored embedding blob back into floats; skip empty ones.
            let bytes = sqlite3_column_bytes(statement, 2)
            guard bytes > 0, let blob = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: blob, count: Int(bytes))
            let embedding = [Float](embeddingData: data)
            let score = VectorMath.cosineSimilarity(queryEmbedding, embedding)
            hits.append(VectorSearchHit(memoryID: memoryID, text: text, score: score))
        }

        // Best matches first, capped at topK (clamped to be non-negative).
        return hits
            .sorted { $0.score > $1.score }
            .prefix(max(topK, 0))
            .map { $0 }
    }

    /// Number of vectors currently in the index (returns 0 if the query yields
    /// no row).
    public func count() throws -> Int {
        let sql = "SELECT COUNT(*) FROM memory_vectors;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// The set of `memory_id`s currently present in the index.
    ///
    /// Used to find records that exist in the canonical store but were never
    /// embedded (e.g. saved while the embedder was unavailable) so they can be
    /// re-indexed once embeddings come back online.
    public func indexedMemoryIDs() throws -> Set<String> {
        let sql = "SELECT memory_id FROM memory_vectors;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.insert(String(cString: cString))
            }
        }
        return ids
    }

    private func metadataValue(for key: String) -> String? {
        let sql = "SELECT value FROM index_metadata WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: cString)
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let sql = """
        INSERT INTO index_metadata(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorIndexError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    /// Runs a statement that returns no rows (e.g. DDL), throwing on failure.
    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw VectorIndexError.execFailed(errorMessage)
        }
    }

    /// The most recent SQLite error message for the open database.
    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}

/// Sentinel telling SQLite to copy bound buffers, since the Swift values backing
/// them don't outlive the `bind`/`step` call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
