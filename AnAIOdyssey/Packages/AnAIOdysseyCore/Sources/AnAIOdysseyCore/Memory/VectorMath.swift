// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Small pure-math helpers for working with embedding vectors.
///
/// Used by the vector index and embedding services to score and normalize
/// vectors without pulling in a heavier numerics dependency.
public enum VectorMath {
    /// Cosine similarity between two equal-length vectors, in the range
    /// roughly [-1, 1] where higher means more similar.
    ///
    /// Returns 0 for mismatched-length, empty, or zero-magnitude inputs so
    /// callers never have to special-case degenerate vectors.
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        // Accumulate the dot product and each vector's squared magnitude in one pass.
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        // Guard against division by zero when either vector has no magnitude.
        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    /// Scales `vector` in place to unit length (L2 norm). No-ops on a zero
    /// vector to avoid producing NaNs.
    public static func normalize(_ vector: inout [Float]) {
        var sumSquares: Float = 0
        for value in vector {
            sumSquares += value * value
        }
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return }
        for index in vector.indices {
            vector[index] /= norm
        }
    }
}

/// Conversions between `[Float]` embeddings and the raw `Data` blob stored in
/// SQLite. The on-disk format is simply the floats' native little-endian bytes.
extension Array where Element == Float {
    /// Reconstructs a float vector from its raw byte blob (as written by
    /// `embeddingData`).
    public init(embeddingData data: Data) {
        self = data.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

    /// The vector's raw bytes, suitable for binding as a SQLite BLOB.
    public var embeddingData: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
