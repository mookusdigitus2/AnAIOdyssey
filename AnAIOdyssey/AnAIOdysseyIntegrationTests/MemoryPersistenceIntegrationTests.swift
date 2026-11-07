// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class MemoryPersistenceIntegrationTests: XCTestCase {
    func testMemorySurvivesRelaunch() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let storeURL = tempDirectory.appendingPathComponent("memories.store")
        let vectorURL = tempDirectory.appendingPathComponent("vectors.sqlite")
        let configuration = ModelConfiguration(url: storeURL)

        let container = try ModelContainer(for: AnAIOdysseySchema.schema, configurations: configuration)
        let context = ModelContext(container)
        let repositories = RepositoryBundle.live(context: context)
        let vectorStore = try VectorIndexStore(databaseURL: vectorURL)
        let service = MemoryService(
            memories: repositories.memories,
            vectorStore: vectorStore,
            embeddingService: MockEmbeddingService()
        )

        let saved = try await service.save(text: "User prefers dark mode")
        let savedID = saved.id

        let relaunchedContainer = try ModelContainer(for: AnAIOdysseySchema.schema, configurations: configuration)
        let relaunchedContext = ModelContext(relaunchedContainer)
        let relaunchedRepositories = RepositoryBundle.live(context: relaunchedContext)
        let relaunchedVectorStore = try VectorIndexStore(databaseURL: vectorURL)
        let relaunchedService = MemoryService(
            memories: relaunchedRepositories.memories,
            vectorStore: relaunchedVectorStore,
            embeddingService: MockEmbeddingService()
        )

        let fetched = try relaunchedService.fetch(id: savedID)
        XCTAssertEqual(fetched?.text, "User prefers dark mode")

        let results = try await relaunchedService.search(query: "theme preference", topK: 1)
        XCTAssertEqual(results.first?.memory.id, savedID)
    }
}
