// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftUI

/// A memory paired with its relevance score from a semantic search.
public struct MemorySearchResult: Equatable {
    /// The matched memory record.
    public let memory: Memory
    /// Cosine-similarity score from the vector index; higher is more relevant.
    public let score: Float

    public init(memory: Memory, score: Float) {
        self.memory = memory
        self.score = score
    }
}

/// Health of the embedding backend, surfaced so the UI can warn the user instead
/// of memory writes failing (or succeeding but silently going unindexed).
public enum EmbedderHealth: Equatable, Sendable {
    /// Not yet loaded/probed.
    case unknown
    /// Loaded and producing embeddings.
    case ready
    /// Load or embedding failed; carries a human-readable reason. Memories are
    /// still saved, just not searchable until the embedder recovers.
    case unavailable(String)
}

/// Coordinates the two halves of long-term memory: the SwiftData record store
/// and the SQLite vector index.
///
/// Every mutation goes through here so the canonical `Memory` rows and their
/// embeddings never drift apart. `@MainActor` because it touches the
/// main-actor-bound repository and embedding service.
@MainActor
public final class MemoryService {
    /// Canonical store of `Memory` records.
    public let memories: any MemoryRepositoryProtocol
    /// Embedding index used for similarity search.
    public let vectorStore: VectorIndexStore
    /// Backend that turns text into embedding vectors.
    public let embeddingService: any EmbeddingServiceProtocol

    /// Current health of the embedding backend (for UI surfacing/health checks).
    public private(set) var embedderHealth: EmbedderHealth = .unknown

    /// In-flight model load, cached so concurrent callers share one load instead
    /// of each triggering their own.
    private var readyTask: Task<Void, Error>?

    /// Injects the three collaborators (record store, vector index, embedder).
    public init(
        memories: any MemoryRepositoryProtocol,
        vectorStore: VectorIndexStore,
        embeddingService: any EmbeddingServiceProtocol
    ) {
        self.memories = memories
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
    }

    /// Ensures the embedding model is loaded, loading it once if needed.
    ///
    /// Single-flight: concurrent callers await the same load. Updates
    /// `embedderHealth` and rethrows on failure so callers can fall back.
    @discardableResult
    public func ensureEmbedderReady() async throws -> Bool {
        if embeddingService.isModelLoaded {
            embedderHealth = .ready
            return true
        }
        if let readyTask {
            try await readyTask.value
            return embeddingService.isModelLoaded
        }
        let service = embeddingService
        let task = Task { try await service.loadModel() }
        readyTask = task
        do {
            try await task.value
            embedderHealth = .ready
            return true
        } catch {
            // Clear the cached task so a later attempt can retry the load.
            readyTask = nil
            embedderHealth = .unavailable(Self.describe(error))
            throw error
        }
    }

    /// Warms the embedder at startup and re-indexes anything that was saved while
    /// it was unavailable. Never throws — startup should not be blocked by a
    /// transient embedding failure.
    public func warmUp() async {
        do {
            try await ensureEmbedderReady()
            try reconcileEmbeddingIndexVersion()
            await reindexPending()
        } catch {
            // Health is already recorded; saves will retry indexing on demand.
        }
    }

    /// Clears and rebuilds the vector index when the embedding model or dimension changes.
    private func reconcileEmbeddingIndexVersion() throws {
        let modelID = embeddingService.modelIdentifier
        let dimension = embeddingService.embeddingDimension
        if let stored = vectorStore.storedEmbeddingMetadata(),
           stored.modelID == modelID,
           stored.dimension == dimension {
            return
        }
        try vectorStore.clearAllVectors()
        try vectorStore.setEmbeddingMetadata(modelID: modelID, dimension: dimension)
    }

    /// Persists a new memory and indexes its embedding for later search.
    ///
    /// Rejects blank input and de-duplicates: if an identical memory already
    /// exists (same normalized text, and same session when one is given) it is
    /// reused instead of creating a duplicate. If embeddings are currently
    /// unavailable the record is still saved and queued for re-indexing rather
    /// than failing the whole save (graceful degradation).
    @discardableResult
    public func save(text: String, sessionID: String? = nil) async throws -> Memory {
        // Reject whitespace-only input early.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryError.notFound("empty-memory-text")
        }

        // De-dupe chat summaries / preferences: reuse an existing identical memory
        // rather than piling up duplicates. Make a best-effort attempt to index it
        // in case the earlier save couldn't.
        if let existing = try existingDuplicate(of: trimmed, sessionID: sessionID) {
            await indexIfNeeded(memoryID: existing.id, text: existing.text)
            return existing
        }

        // Create the canonical record first so the memory is never lost, then try
        // to index its embedding under the same id.
        let memory = try memories.createMemory(text: trimmed, sessionID: sessionID)
        await indexIfNeeded(memoryID: memory.id, text: trimmed)
        return memory
    }

    /// Returns up to `topK` memories most relevant to `query`, best first.
    ///
    /// Embeds the query, searches the vector index, then resolves each hit back
    /// to its full `Memory`. If embeddings are unavailable this returns an empty
    /// result (degraded) instead of throwing. Hits whose record no longer exists
    /// are silently dropped (keeps results consistent if the stores diverge).
    public func search(query: String, topK: Int = 5) async throws -> [MemorySearchResult] {
        // Blank queries can't match anything.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Embed the query into the same space as the stored vectors. If the
        // embedder is down, degrade to no results rather than surfacing an error.
        let queryEmbedding: [Float]
        do {
            try await ensureEmbedderReady()
            let vectors = try await embeddingService.embed(texts: [trimmed])
            guard let first = vectors.first else { return [] }
            queryEmbedding = first
        } catch {
            embedderHealth = .unavailable(Self.describe(error))
            return []
        }

        // Look up nearest vectors, then hydrate each into a full record.
        let hits = try vectorStore.search(queryEmbedding: queryEmbedding, topK: topK)
        var results: [MemorySearchResult] = []
        for hit in hits {
            if let memory = try memories.fetchMemory(id: hit.memoryID) {
                results.append(MemorySearchResult(memory: memory, score: hit.score))
            }
        }
        return results
    }

    /// Re-embeds any memories that exist as records but are missing from the
    /// vector index (e.g. saved while the embedder was unavailable). No-op if the
    /// embedder still isn't ready. Returns the number of records re-indexed.
    @discardableResult
    public func reindexPending() async -> Int {
        guard (try? await ensureEmbedderReady()) == true else { return 0 }
        let indexed = (try? vectorStore.indexedMemoryIDs()) ?? []
        let all = (try? memories.listMemories()) ?? []
        var repaired = 0
        for memory in all where !indexed.contains(memory.id) {
            if await indexIfNeeded(memoryID: memory.id, text: memory.text) {
                repaired += 1
            }
        }
        return repaired
    }

    /// Embeds `text` and upserts its vector. Returns whether indexing succeeded;
    /// on failure it records the degraded health and leaves the record un-indexed
    /// so `reindexPending()` can retry later.
    @discardableResult
    private func indexIfNeeded(memoryID: String, text: String) async -> Bool {
        do {
            try await ensureEmbedderReady()
            let vectors = try await embeddingService.embed(texts: [text])
            guard let embedding = vectors.first else {
                embedderHealth = .unavailable("No embedding returned.")
                return false
            }
            try vectorStore.setEmbeddingMetadata(
                modelID: embeddingService.modelIdentifier,
                dimension: embedding.count
            )
            try vectorStore.upsert(memoryID: memoryID, text: text, embedding: embedding)
            embedderHealth = .ready
            return true
        } catch {
            embedderHealth = .unavailable(Self.describe(error))
            return false
        }
    }

    /// Finds an existing memory with the same normalized text, scoped to the
    /// session when one is supplied (so the same summary in different chats stays
    /// distinct, while a repeated global preference de-dupes).
    private func existingDuplicate(of text: String, sessionID: String?) throws -> Memory? {
        let normalized = Self.normalize(text)
        return try memories.listMemories().first { candidate in
            Self.normalize(candidate.text) == normalized
                && (sessionID == nil || candidate.sessionID == sessionID)
        }
    }

    /// Normalizes text for duplicate comparison (trim + case-fold).
    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Best-effort human-readable description for an embedding error.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Deletes a memory from both the record store and the vector index.
    public func delete(id: String) throws {
        try memories.deleteMemory(id: id)
        try vectorStore.delete(memoryID: id)
    }

    /// All stored memories (record store only; no scoring).
    public func listAll() throws -> [Memory] {
        try memories.listMemories()
    }

    /// Fetches a single memory by id, or `nil` if it doesn't exist.
    public func fetch(id: String) throws -> Memory? {
        try memories.fetchMemory(id: id)
    }
}

/// Resolves on-disk locations for memory storage.
public enum MemoryStorageLocations {
    /// Path of the SQLite vector index inside the app-support directory.
    public static func vectorDatabaseURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("memory_vectors.sqlite")
    }
}

/// Environment key backing the optional `memoryService` value.
private struct MemoryServiceKey: EnvironmentKey {
    static let defaultValue: MemoryService? = nil
}

/// SwiftUI environment access to the shared `MemoryService` so views can perform
/// memory operations without manual dependency threading.
public extension EnvironmentValues {
    var memoryService: MemoryService? {
        get { self[MemoryServiceKey.self] }
        set { self[MemoryServiceKey.self] = newValue }
    }
}
