// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// A head-to-head "which model answered better?" evaluation between two models
/// for the same prompt (an arena / blind-taste-test record).
///
/// Supports blind voting: when `isBlind` is true the UI hides which response
/// came from which model, and `blindMappingJSON` records the hidden A/B → model
/// assignment so the result can be revealed after voting.
@Model
public final class Comparison {
    /// Stable identifier (UUID string).
    public var id: String = ""
    /// The shared prompt sent to both models.
    public var prompt: String = ""
    /// Identifiers of the two competing models.
    public var modelA: String = ""
    public var modelB: String = ""
    /// The respective responses; optional because they may still be streaming or
    /// have failed to generate.
    public var responseA: String?
    public var responseB: String?
    /// Which side the user picked ("A"/"B"/tie convention decided by the UI);
    /// `nil` until a vote is recorded.
    public var winner: String?
    /// Whether model identities are hidden from the voter.
    public var isBlind: Bool = true
    /// JSON mapping of the shuffled blind labels back to real models, used to
    /// de-anonymize after a blind vote.
    public var blindMappingJSON: String?
    /// When the vote was cast; `nil` while the comparison is still pending.
    public var votedAt: Date?
    /// JSON array of ``CompareSlotResult`` for N-model and image comparisons.
    public var resultsJSON: String?

    /// Creates a comparison; `id` defaults to a fresh UUID and comparisons start
    /// blind by default.
    public init(
        id: String = UUID().uuidString,
        prompt: String,
        modelA: String,
        modelB: String,
        responseA: String? = nil,
        responseB: String? = nil,
        winner: String? = nil,
        isBlind: Bool = true,
        blindMappingJSON: String? = nil,
        votedAt: Date? = nil,
        resultsJSON: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.modelA = modelA
        self.modelB = modelB
        self.responseA = responseA
        self.responseB = responseB
        self.winner = winner
        self.isBlind = isBlind
        self.blindMappingJSON = blindMappingJSON
        self.votedAt = votedAt
        self.resultsJSON = resultsJSON
    }

    public var slotResults: [CompareSlotResult] {
        guard let resultsJSON,
              let data = resultsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CompareSlotResult].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// One model’s output in a multi-model comparison.
public struct CompareSlotResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String { selectionKey }
    public var selectionKey: String
    public var modelID: String
    public var displayName: String
    public var kind: String
    public var text: String?
    public var imagePath: String?

    public init(
        selectionKey: String,
        modelID: String,
        displayName: String,
        kind: String,
        text: String? = nil,
        imagePath: String? = nil
    ) {
        self.selectionKey = selectionKey
        self.modelID = modelID
        self.displayName = displayName
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
    }

    public var isImage: Bool { kind == "image" }
}
