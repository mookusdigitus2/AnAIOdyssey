// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import MLX
import MLXEmbedders
import AnAIOdysseyCore

/// On-device text embedding backend (MLX + the BGE-micro model) used for semantic memory search.
///
/// Produces normalized embedding vectors entirely locally so memory search works
/// offline and privately. The actual `embeddingDimension` is discovered at load
/// time by embedding a probe string, since it depends on the loaded model.
@MainActor
public final class MLXEmbeddingService: EmbeddingServiceProtocol {
    public let modelIdentifier = "mlx-bge-micro"
    /// Output vector length; seeded with the mock default, then corrected after load.
    public private(set) var embeddingDimension = MockEmbeddingService.defaultDimension
    public private(set) var isModelLoaded = false

    /// The loaded embedding model + tokenizer + pooler; `nil` until `loadModel`.
    private var modelContainer: MLXEmbedders.ModelContainer?

    /// In-flight load, cached so concurrent callers share a single model load
    /// instead of each kicking off their own (which would be wasteful/unsafe).
    private var loadTask: Task<Void, Error>?

    public init() {}

    /// Loads the embedding model and calibrates `embeddingDimension` from a probe
    /// embedding. Idempotent and safe to call concurrently: repeat calls await the
    /// same in-flight load rather than reloading.
    public func loadModel() async throws {
        if isModelLoaded { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task { try await performLoad() }
        loadTask = task
        do {
            try await task.value
        } catch {
            // Allow a later retry after a transient failure.
            loadTask = nil
            throw error
        }
    }

    /// Actually loads the model container and probes the output dimension.
    private func performLoad() async throws {
        modelContainer = try await loadModelContainer(configuration: .bge_micro)
        isModelLoaded = true

        // Discover the true vector length by embedding a throwaway string.
        let probe = try await embed(texts: ["dimension probe"])
        embeddingDimension = probe.first?.count ?? embeddingDimension
    }

    /// Embeds each input string into a normalized vector, processing them one at a time.
    ///
    /// Each text is tokenized, run through the model, mean/CLS-pooled and L2-normalized
    /// (so cosine similarity reduces to a dot product), then materialized to `[Float]`.
    public func embed(texts: [String]) async throws -> [[Float]] {
        // Lazily load on first use so callers never have to remember to warm the
        // model up first. (`performLoad` sets `modelContainer` before its own
        // probe embed, so this doesn't recurse.)
        if modelContainer == nil {
            try await loadModel()
        }
        guard let modelContainer else {
            throw EmbeddingServiceError.modelNotLoaded
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)

        for text in texts {
            // Run tokenize → forward → pool on the container's isolated context.
            let vector = await modelContainer.perform { model, tokenizer, pooler in
                let tokens = tokenizer.encode(text: text)
                // Add a batch dimension of 1 for the single input.
                let input = MLXArray(tokens).expandedDimensions(axis: 0)
                let output = model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                let pooled = pooler(output, normalize: true)
                // Force lazy MLX computation before reading the values out.
                eval(pooled)
                return pooled[0].asArray(Float.self)
            }
            vectors.append(vector)
        }

        return vectors
    }
}
