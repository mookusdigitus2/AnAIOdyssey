// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// SwiftData-backed implementation of `ComparisonRepositoryProtocol`.
@MainActor
public final class SwiftDataComparisonRepository: ComparisonRepositoryProtocol {
    /// The shared SwiftData context all operations run against.
    private let context: ModelContext

    /// Binds the repository to a `ModelContext`.
    public init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    public func createComparison(
        prompt: String,
        modelA: String,
        modelB: String,
        responseA: String?,
        responseB: String?,
        isBlind: Bool,
        blindMappingJSON: String?,
        resultsJSON: String? = nil
    ) throws -> Comparison {
        let comparison = Comparison(
            prompt: prompt,
            modelA: modelA,
            modelB: modelB,
            responseA: responseA,
            responseB: responseB,
            isBlind: isBlind,
            blindMappingJSON: blindMappingJSON,
            resultsJSON: resultsJSON
        )
        context.insert(comparison)
        try save()
        return comparison
    }

    public func fetchComparison(id: String) throws -> Comparison? {
        let descriptor = FetchDescriptor<Comparison>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public func listComparisons() throws -> [Comparison] {
        // Sort in memory: voted comparisons first (most recent vote first), then
        // unvoted ones (stably ordered by id). `votedAt` is optional, so this
        // can't be a plain SwiftData sort descriptor.
        let descriptor = FetchDescriptor<Comparison>()
        let rows = try context.fetch(descriptor)
        return rows.sorted { lhs, rhs in
            switch (lhs.votedAt, rhs.votedAt) {
            case let (left?, right?):
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id > rhs.id
            }
        }
    }

    public func updateComparison(
        id: String,
        responseA: String?,
        responseB: String?,
        winner: String?,
        votedAt: Date?
    ) throws {
        guard let comparison = try fetchComparison(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Partial update: only overwrite fields that were supplied.
        if let responseA {
            comparison.responseA = responseA
        }
        if let responseB {
            comparison.responseB = responseB
        }
        if let winner {
            comparison.winner = winner
        }
        if let votedAt {
            comparison.votedAt = votedAt
        }
        try save()
    }

    public func recordVote(id: String, winner: String) throws {
        guard let comparison = try fetchComparison(id: id) else {
            throw RepositoryError.notFound(id)
        }
        // Record the choice and stamp the vote time so it sorts to the top.
        comparison.winner = winner
        comparison.votedAt = .now
        try save()
    }

    public func deleteComparison(id: String) throws {
        guard let comparison = try fetchComparison(id: id) else {
            throw RepositoryError.notFound(id)
        }
        context.delete(comparison)
        try save()
    }

    public func save() throws {
        try context.save()
    }
}
