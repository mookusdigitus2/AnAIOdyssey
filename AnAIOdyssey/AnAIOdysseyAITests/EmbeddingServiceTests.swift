// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyAI
@testable import AIConnect
@testable import AIConnectVoice
@testable import AnAIOdysseyCore
import AnAIOdysseyMLX

@MainActor
final class EmbeddingServiceTests: XCTestCase {
    func testMockEmbeddingDimension() async throws {
        let service = MockEmbeddingService()
        try await service.loadModel()
        let vectors = try await service.embed(texts: ["dimension check"])
        XCTAssertEqual(vectors.first?.count, service.embeddingDimension)
        XCTAssertEqual(service.embeddingDimension, MockEmbeddingService.defaultDimension)
    }

    func testMLXEmbeddingDimensionOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["MLX_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("MLX embedding tests require MLX_DEVICE_TESTS=1 on physical hardware")
        }

        let service = MLXEmbeddingService()
        try await service.loadModel()
        let vectors = try await service.embed(texts: ["Hello MLX embeddings"])
        XCTAssertEqual(vectors.first?.count, service.embeddingDimension)
        XCTAssertGreaterThan(service.embeddingDimension, 0)
    }
}
