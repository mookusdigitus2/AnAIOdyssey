// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import SwiftUI

/// One selected model for a comparison run.
public struct CompareSelection: Equatable, Sendable {
    public var selectionKey: String
    public var modelID: String
    public var displayName: String
    public var connectionID: String?

    public init(
        selectionKey: String,
        modelID: String,
        displayName: String,
        connectionID: String? = nil
    ) {
        self.selectionKey = selectionKey
        self.modelID = modelID
        self.displayName = displayName
        self.connectionID = connectionID
    }
}

/// Maps the two on-screen sides ("left"/"right") to the two models ("a"/"b") in a blind comparison.
///
/// Persisted with each comparison so the original assignment can be recovered
/// when displaying results, keeping which model produced which answer hidden from
/// the voter until they choose.
public struct BlindMapping: Codable, Sendable, Equatable {
    public let left: String
    public let right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }

    /// Randomly assigns models a/b to the left/right slots so the voter can't infer identity from position.
    public static func randomAssignment() -> BlindMapping {
        Bool.random()
            ? BlindMapping(left: "a", right: "b")
            : BlindMapping(left: "b", right: "a")
    }
}

/// Errors thrown while running or voting on a model comparison, with display-ready messages.
public enum CompareServiceError: Error, LocalizedError {
    case emptyPrompt
    case modelNotLoaded
    case generationFailed(String)
    case invalidWinner

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "Enter a prompt to compare."
        case .modelNotLoaded:
            "No model is loaded. Open Settings and load a model first."
        case .generationFailed(let message):
            "Comparison failed: \(message)"
        case .invalidWinner:
            "Winner must be a, b, or tie."
        }
    }
}

/// Runs side-by-side model comparisons ("which answer is better?") and records the outcomes.
///
/// Generates a response from each of two models for the same prompt, optionally
/// blinding which is which, persists the pair, and later records the user's vote.
@MainActor
public final class CompareService {
    private let llmService: any LLMServiceProtocol
    private let providerSettings: ProviderSettings
    /// Persistence for comparison runs and votes.
    public let comparisons: any ComparisonRepositoryProtocol

    public init(
        llmService: any LLMServiceProtocol,
        providerSettings: ProviderSettings,
        comparisons: any ComparisonRepositoryProtocol
    ) {
        self.llmService = llmService
        self.providerSettings = providerSettings
        self.comparisons = comparisons
    }

    /// Lists previously saved comparisons.
    public func listComparisons() throws -> [Comparison] {
        try comparisons.listComparisons()
    }

    /// Deletes a saved comparison by id.
    public func deleteComparison(id: String) throws {
        try comparisons.deleteComparison(id: id)
    }

    /// Generates both responses for `prompt` and stores the comparison.
    ///
    /// The two models run sequentially (slot A then slot B); when `isBlind`, the
    /// left/right display order is randomized and saved so results stay blind.
    public func startComparison(
        prompt: String,
        modelA: String,
        modelB: String,
        isBlind: Bool = true
    ) async throws -> Comparison {
        try await startComparison(
            prompt: prompt,
            selections: [
                CompareSelection(selectionKey: modelA, modelID: modelA, displayName: modelA),
                CompareSelection(selectionKey: modelB, modelID: modelB, displayName: modelB),
            ],
            isBlind: isBlind
        )
    }

    public func startComparison(
        prompt: String,
        selections: [CompareSelection],
        isBlind: Bool = false
    ) async throws -> Comparison {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompareServiceError.emptyPrompt
        }
        guard selections.count >= 2 else {
            throw CompareServiceError.emptyPrompt
        }

        let mapping = isBlind && selections.count == 2
            ? BlindMapping.randomAssignment()
            : BlindMapping(left: "a", right: "b")
        let mappingJSON = try Self.encodeMapping(mapping)

        var slots: [CompareSlotResult] = []
        for (index, selection) in selections.enumerated() {
            slots.append(
                try await completeSlot(
                    prompt: trimmed,
                    selection: selection,
                    slot: index + 1
                )
            )
        }

        let resultsData = try JSONEncoder().encode(slots)
        let resultsJSON = String(data: resultsData, encoding: .utf8)
        let first = slots[0]
        let second = slots[1]
        return try comparisons.createComparison(
            prompt: trimmed,
            modelA: first.displayName,
            modelB: second.displayName,
            responseA: first.text,
            responseB: second.text,
            isBlind: isBlind && selections.count == 2 && slots.allSatisfy { !$0.isImage },
            blindMappingJSON: mappingJSON,
            resultsJSON: resultsJSON
        )
    }

    private func completeSlot(
        prompt: String,
        selection: CompareSelection,
        slot: Int
    ) async throws -> CompareSlotResult {
        if OpenAICompatibleAPI.isImageGenerationModel(selection.modelID) {
            let data = try await generateImage(prompt: prompt, selection: selection)
            let path = try Self.writeCompareImage(data, modelID: selection.modelID)
            return CompareSlotResult(
                selectionKey: selection.selectionKey,
                modelID: selection.modelID,
                displayName: selection.displayName,
                kind: "image",
                imagePath: path
            )
        }
        let text = try await complete(prompt: prompt, selection: selection, slot: "\(slot)")
        return CompareSlotResult(
            selectionKey: selection.selectionKey,
            modelID: selection.modelID,
            displayName: selection.displayName,
            kind: "text",
            text: text
        )
    }

    private func generateImage(prompt: String, selection: CompareSelection) async throws -> Data {
        let remote: RemoteLLMService?
        if let service = llmService as? RemoteLLMService {
            remote = service
        } else if let providing = llmService as? AgentRemoteLLMProviding {
            remote = providing.remoteServiceForAgent
        } else {
            remote = nil
        }
        guard let remote else {
            throw CompareServiceError.generationFailed("Image comparison needs a remote image model.")
        }
        let parsed = ConfiguredModelRegistry.parseSelectionKey(selection.selectionKey)
        try await LLMModelPreparer.prepare(
            llmService: remote,
            providerSettings: providerSettings,
            modelID: selection.modelID,
            backend: .remote,
            connectionID: parsed?.connectionID ?? selection.connectionID
        )
        do {
            return try await remote.generateImage(prompt: prompt, modelID: selection.modelID)
        } catch {
            throw CompareServiceError.generationFailed(error.localizedDescription)
        }
    }

    private static func writeCompareImage(_ data: Data, modelID: String) throws -> String {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnAIOdyssey/compare-images", isDirectory: true)
        guard let folder else {
            throw CompareServiceError.generationFailed("Could not save comparison image.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString)-\(modelID.replacingOccurrences(of: "/", with: "-")).png"
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    /// Records the winner ("a"/"b"/"tie") for a comparison and returns the updated record. Validates the value first.
    public func recordVote(comparisonID: String, winner: String) throws -> Comparison {
        let normalized = winner.lowercased()
        guard ["a", "b", "tie"].contains(normalized) else {
            throw CompareServiceError.invalidWinner
        }
        try comparisons.recordVote(id: comparisonID, winner: normalized)
        guard let comparison = try comparisons.fetchComparison(id: comparisonID) else {
            throw RepositoryError.notFound(comparisonID)
        }
        return comparison
    }

    /// Decodes the stored blind mapping for a comparison, or `nil` if absent/corrupt.
    public static func decodeMapping(from comparison: Comparison) -> BlindMapping? {
        guard let json = comparison.blindMappingJSON,
              let data = json.data(using: .utf8),
              let mapping = try? JSONDecoder().decode(BlindMapping.self, from: data) else {
            return nil
        }
        return mapping
    }

    /// Returns the responses in display (left/right) order, applying the blind mapping when present.
    ///
    /// For non-blind comparisons, left=A and right=B; for blind ones the saved
    /// mapping decides which model's answer appears on each side.
    public static func displayResponses(for comparison: Comparison) -> (left: String, right: String) {
        let responseA = comparison.responseA ?? ""
        let responseB = comparison.responseB ?? ""
        guard comparison.isBlind, let mapping = decodeMapping(from: comparison) else {
            return (responseA, responseB)
        }
        let left = mapping.left == "a" ? responseA : responseB
        let right = mapping.right == "a" ? responseA : responseB
        return (left, right)
    }

    /// Loads `selection`, streams a full response for `prompt`, and returns it trimmed.
    ///
    /// Accumulates the streamed chunks into one string (the comparison view shows
    /// whole answers, not a live stream) and treats empty output as a failure.
    private func complete(prompt: String, selection: CompareSelection, slot: String) async throws -> String {
        let parsed = ConfiguredModelRegistry.parseSelectionKey(selection.selectionKey)
        do {
            try await LLMModelPreparer.prepare(
                llmService: llmService,
                providerSettings: providerSettings,
                modelID: selection.modelID,
                backend: parsed?.backend
                    ?? ConfiguredModelRegistry.inferredBackend(
                        for: selection.modelID,
                        providerSettings: providerSettings
                    ),
                connectionID: parsed?.connectionID ?? selection.connectionID
            )
        } catch {
            throw CompareServiceError.modelNotLoaded
        }
        // Tell the model which slot it's playing so prompts stay symmetric.
        let systemPrompt = """
        You are model slot \(slot) (\(selection.modelID)). Answer clearly and concisely.
        """
        var output = ""
        let stream = llmService.streamResponse(
            to: prompt,
            history: [LLMChatTurn(role: "system", content: systemPrompt)]
        )
        // Collect the entire stream before returning.
        do {
            for try await chunk in stream {
                output += chunk
            }
        } catch {
            throw CompareServiceError.generationFailed(error.localizedDescription)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompareServiceError.generationFailed("Empty response from model \(selection.modelID).")
        }
        return trimmed
    }

    /// JSON-encodes the blind mapping for persistence with the comparison.
    private static func encodeMapping(_ mapping: BlindMapping) throws -> String {
        let data = try JSONEncoder().encode(mapping)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CompareServiceError.generationFailed("Could not encode blind mapping.")
        }
        return json
    }
}

/// Environment key making the active `CompareService` reachable from SwiftUI views.
private struct CompareServiceKey: EnvironmentKey {
    static let defaultValue: CompareService? = nil
}

public extension EnvironmentValues {
    /// The comparison service available to the current view tree.
    var compareService: CompareService? {
        get { self[CompareServiceKey.self] }
        set { self[CompareServiceKey.self] = newValue }
    }
}
