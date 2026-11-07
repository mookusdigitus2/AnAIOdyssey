// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Deterministic embedding backend for unit tests and Simulator UI runs.
///
/// Produces stable, dependency-free vectors so memory search behaves
/// predictably without loading a real ML model. The vectors are crafted so that
/// topically-related text (e.g. two programming notes) lands near each other,
/// which is enough to exercise the search pipeline end to end.
@MainActor
public final class MockEmbeddingService: EmbeddingServiceProtocol {
    /// Default vector length, matching a common small sentence-embedding size.
    nonisolated public static let defaultDimension = 384

    public let modelIdentifier = "mock-embedding-v1"
    public let embeddingDimension: Int
    public private(set) var isModelLoaded = false

    /// Creates a mock service producing vectors of the given dimension.
    public init(dimension: Int = MockEmbeddingService.defaultDimension) {
        self.embeddingDimension = dimension
    }

    /// "Loads" the (non-existent) model by simply flipping the ready flag.
    public func loadModel() async throws {
        isModelLoaded = true
    }

    /// Embeds each input via the deterministic `vector(for:dimension:)` hash,
    /// auto-loading the model first if needed.
    public func embed(texts: [String]) async throws -> [[Float]] {
        if !isModelLoaded {
            try await loadModel()
        }
        return texts.map { Self.vector(for: $0, dimension: embeddingDimension) }
    }

    /// Deterministically maps text to a unit vector.
    ///
    /// A few leading dimensions are reserved as coarse topic "buckets" (so
    /// related domains cluster), and the remaining dimensions get a stable
    /// bag-of-words signal from hashed tokens. The result is normalized so cosine
    /// similarity is meaningful.
    static func vector(for text: String, dimension: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)

        let lower = text.lowercased()
        // Hand-picked topic keyword sets that nudge related text together.
        let programmingKeywords = [
            "swift", "ios", "programming", "development", "xcode", "code", "software",
            "apple", "developer", "tools", "architecture",
        ]
        let cookingKeywords = ["cooking", "recipe", "recipes", "food", "kitchen", "bake", "meal"]

        // Reserve the first dimensions as coarse topic buckets.
        if programmingKeywords.contains(where: { lower.contains($0) }) {
            vector[0] = 1
            vector[1] = 0.8
        }
        if cookingKeywords.contains(where: { lower.contains($0) }) {
            vector[2] = 1
            vector[3] = 0.8
        }

        // Spread a stable bag-of-words signal across the remaining dimensions
        // (offset by 4 to avoid clobbering the topic buckets).
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            let index = abs(token.hashValue) % max(dimension - 4, 1) + 4
            vector[index] += 1
        }

        VectorMath.normalize(&vector)
        return vector
    }
}
