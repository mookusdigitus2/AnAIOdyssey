// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import NaturalLanguage

/// On-device sentence embeddings via Apple's NaturalLanguage framework (iOS/iPadOS).
@MainActor
public final class NLEmbeddingService: EmbeddingServiceProtocol {
    public private(set) var isModelLoaded = false
    public let modelIdentifier = "nl-embedding-sentence-en"

    private var embedding: NLEmbedding?

    public var embeddingDimension: Int {
        embedding?.dimension ?? 512
    }

    public init() {}

    public func loadModel() async throws {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingServiceError.embeddingFailed("NLEmbedding is not available on this device.")
        }
        embedding = model
        isModelLoaded = true
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        if !isModelLoaded {
            try await loadModel()
        }
        guard let embedding else {
            throw EmbeddingServiceError.modelNotLoaded
        }
        return texts.map { text in
            guard let vector = embedding.vector(for: text) else {
                return [Float](repeating: 0, count: embedding.dimension)
            }
            return vector.map { Float($0) }
        }
    }
}
