// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class MemoryServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var memoryService: MemoryService!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let (_, repositories) = try TestModelContainer.makeRepositories()
        let vectorStore = try VectorIndexStore(
            databaseURL: tempDirectory.appendingPathComponent("vectors.sqlite")
        )
        memoryService = MemoryService(
            memories: repositories.memories,
            vectorStore: vectorStore,
            embeddingService: MockEmbeddingService()
        )
    }

    override func tearDownWithError() throws {
        memoryService = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    func testEmbedProducesFixedDimensionVector() async throws {
        let embeddingService = MockEmbeddingService()
        let vectors = try await embeddingService.embed(texts: ["Hello memory"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors[0].count, MockEmbeddingService.defaultDimension)
    }

    func testSimilarTextsRankHigher() async throws {
        let embeddingService = MockEmbeddingService()
        let query = try await embeddingService.embed(texts: ["Swift programming"])
        let candidates = try await embeddingService.embed(
            texts: ["iOS development", "cooking recipes"]
        )
        let queryVector = try XCTUnwrap(query.first)
        let iosScore = VectorMath.cosineSimilarity(queryVector, candidates[0])
        let cookingScore = VectorMath.cosineSimilarity(queryVector, candidates[1])
        XCTAssertGreaterThan(iosScore, cookingScore)
    }

    func testMemorySearchReturnsTopK() async throws {
        let topics = [
            "Swift programming language features",
            "iOS development with SwiftUI",
            "Cooking pasta recipes",
            "Gardening tomatoes in summer",
            "Machine learning model training",
            "Basketball game highlights",
            "Xcode debugging tips",
            "Italian food and wine",
            "Software architecture patterns",
            "Travel plans for Japan",
        ]

        for topic in topics {
            _ = try await memoryService.save(text: topic)
        }

        let results = try await memoryService.search(query: "Apple developer tools", topK: 3)
        XCTAssertEqual(results.count, 3)
        let topTexts = results.map(\.memory.text)
        XCTAssertTrue(topTexts.contains(where: { $0.localizedCaseInsensitiveContains("Xcode") }))
        XCTAssertTrue(topTexts.contains(where: { $0.localizedCaseInsensitiveContains("Swift") }))
    }

    func testMemoryCRUD() async throws {
        let saved = try await memoryService.save(text: "User prefers dark mode")
        XCTAssertEqual(saved.text, "User prefers dark mode")

        let fetched = try memoryService.fetch(id: saved.id)
        XCTAssertEqual(fetched?.text, "User prefers dark mode")

        try memoryService.delete(id: saved.id)
        XCTAssertNil(try memoryService.fetch(id: saved.id))
        XCTAssertTrue(try memoryService.listAll().isEmpty)
    }

    // MARK: - Embedder loading, dedupe & graceful fallback

    /// Builds an isolated service backed by a controllable embedder + fresh index.
    private func makeService(
        embedder: any EmbeddingServiceProtocol
    ) throws -> (MemoryService, VectorIndexStore) {
        let (_, repositories) = try TestModelContainer.makeRepositories()
        let store = try VectorIndexStore(
            databaseURL: tempDirectory.appendingPathComponent("v-\(UUID().uuidString).sqlite")
        )
        let service = MemoryService(
            memories: repositories.memories,
            vectorStore: store,
            embeddingService: embedder
        )
        return (service, store)
    }

    /// Regression: saving must not fail with "model not loaded" just because the
    /// embedder wasn't warmed up first. The service should lazily load it.
    func testSaveLazyLoadsEmbedder() async throws {
        let embedder = ControllableEmbeddingService()
        let (service, _) = try makeService(embedder: embedder)
        XCTAssertFalse(embedder.isModelLoaded)

        let saved = try await service.save(text: "Lazy load me")
        XCTAssertTrue(embedder.isModelLoaded)
        XCTAssertEqual(service.embedderHealth, .ready)

        let results = try await service.search(query: "Lazy load me", topK: 1)
        XCTAssertEqual(results.first?.memory.id, saved.id)
    }

    /// Identical text (after normalization) reuses the existing memory instead of
    /// creating duplicates — for preferences saved with no session scope.
    func testDedupesIdenticalPreferences() async throws {
        let embedder = ControllableEmbeddingService()
        let (service, _) = try makeService(embedder: embedder)

        let first = try await service.save(text: "User prefers dark mode")
        let second = try await service.save(text: "  user prefers DARK mode  ")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try service.listAll().count, 1)
    }

    /// Chat summaries with the same text but different sessions stay distinct;
    /// a repeat within the same session de-dupes.
    func testDedupeIsSessionScoped() async throws {
        let embedder = ControllableEmbeddingService()
        let (service, _) = try makeService(embedder: embedder)

        let a = try await service.save(text: "Daily summary", sessionID: "session-1")
        let b = try await service.save(text: "Daily summary", sessionID: "session-2")
        XCTAssertNotEqual(a.id, b.id)

        let repeated = try await service.save(text: "Daily summary", sessionID: "session-1")
        XCTAssertEqual(a.id, repeated.id)
        XCTAssertEqual(try service.listAll().count, 2)
    }

    /// When embeddings are unavailable, the memory is still saved (not lost) and
    /// gets indexed later once the embedder recovers, via reindexPending().
    func testGracefulFallbackThenReindex() async throws {
        let embedder = ControllableEmbeddingService()
        embedder.failLoad = true
        let (service, store) = try makeService(embedder: embedder)

        let saved = try await service.save(text: "Saved while embeddings were down")
        // Record persists even though indexing failed.
        XCTAssertNotNil(try service.fetch(id: saved.id))
        XCTAssertEqual(try store.count(), 0)
        guard case .unavailable = service.embedderHealth else {
            return XCTFail("Expected degraded embedder health")
        }

        // Search degrades gracefully to empty rather than throwing.
        let degraded = try await service.search(query: "down", topK: 1)
        XCTAssertTrue(degraded.isEmpty)

        // Embedder recovers; pending records get indexed.
        embedder.failLoad = false
        let repaired = await service.reindexPending()
        XCTAssertEqual(repaired, 1)
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(service.embedderHealth, .ready)

        let results = try await service.search(query: "Saved while embeddings were down", topK: 1)
        XCTAssertEqual(results.first?.memory.id, saved.id)
    }

    func testEmbeddingModelChangeClearsStaleVectors() async throws {
        let embedderA = VersionedMockEmbeddingService(modelID: "model-a", dimension: 384)
        let (service, store) = try makeService(embedder: embedderA)
        _ = try await service.save(text: "First memory")
        XCTAssertEqual(try store.count(), 1)

        let embedderB = VersionedMockEmbeddingService(modelID: "model-b", dimension: 384)
        let upgraded = MemoryService(
            memories: service.memories,
            vectorStore: store,
            embeddingService: embedderB
        )
        await upgraded.warmUp()
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(store.storedEmbeddingMetadata()?.modelID, "model-b")
    }
}

/// A test embedder whose load can be made to fail and which (like the real MLX
/// backend) refuses to embed until explicitly loaded.
@MainActor
private final class ControllableEmbeddingService: EmbeddingServiceProtocol {
    let modelIdentifier = "controllable-mock"
    let embeddingDimension = MockEmbeddingService.defaultDimension
    private(set) var isModelLoaded = false
    /// When true, `loadModel()` throws to simulate an unavailable embedder.
    var failLoad = false
    /// Number of load attempts, for asserting single-flight behavior.
    private(set) var loadCount = 0

    func loadModel() async throws {
        loadCount += 1
        if failLoad {
            throw EmbeddingServiceError.modelNotLoaded
        }
        isModelLoaded = true
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard isModelLoaded else { throw EmbeddingServiceError.modelNotLoaded }
        return texts.map { MockEmbeddingService.vector(for: $0, dimension: embeddingDimension) }
    }
}

@MainActor
private final class VersionedMockEmbeddingService: EmbeddingServiceProtocol {
    let modelIdentifier: String
    let embeddingDimension: Int
    private(set) var isModelLoaded = false

    init(modelID: String, dimension: Int) {
        self.modelIdentifier = modelID
        self.embeddingDimension = dimension
    }

    func loadModel() async throws {
        isModelLoaded = true
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        if !isModelLoaded { try await loadModel() }
        return texts.map { MockEmbeddingService.vector(for: $0, dimension: embeddingDimension) }
    }
}
