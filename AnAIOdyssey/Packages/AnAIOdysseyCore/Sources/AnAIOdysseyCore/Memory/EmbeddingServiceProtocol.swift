// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Errors surfaced while loading an embedding model or generating embeddings.
public enum EmbeddingServiceError: Error, LocalizedError {
    /// `embed` was called before the model finished loading.
    case modelNotLoaded
    /// The backend failed to produce an embedding; carries a human-readable reason.
    case embeddingFailed(String)

    /// User-facing description for surfacing in alerts/logs.
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "Embedding model is not loaded."
        case .embeddingFailed(let message):
            "Embedding failed: \(message)"
        }
    }
}

/// Abstraction over a text-embedding backend used for semantic memory search.
///
/// Decoupling `MemoryService` from any concrete model lets the app swap in a
/// real on-device model in production and a deterministic `MockEmbeddingService`
/// in tests/Simulator. `@MainActor` because conforming services are reference
/// types driven from the main actor.
@MainActor
public protocol EmbeddingServiceProtocol: AnyObject {
    /// Stable identifier for the embedding model (used to invalidate stale vectors).
    var modelIdentifier: String { get }
    /// Length of the vectors this service produces (must match the index).
    var embeddingDimension: Int { get }
    /// Whether the model has been loaded and is ready to embed.
    var isModelLoaded: Bool { get }

    /// Loads/warms up the underlying model; safe to call more than once.
    func loadModel() async throws
    /// Embeds a batch of strings, returning one vector per input in order.
    func embed(texts: [String]) async throws -> [[Float]]
}
