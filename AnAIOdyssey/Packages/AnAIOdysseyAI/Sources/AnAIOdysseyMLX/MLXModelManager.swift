// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import MLXLLM
import MLXLMCommon
import AnAIOdysseyAI
import AIModelOptions

/// MLX-backed implementation of `LocalModelManaging`.
///
/// Lists catalog models with their on-disk state, downloads weights on explicit
/// user request (never automatically), and deletes them. Downloads are gated by
/// the ¾-RAM memory budget so a model that can't actually run can't be fetched.
@MainActor
public final class MLXModelManager: LocalModelManaging {
    public init() {}

    /// Metal GPU, not Simulator, and at least one catalog model fits ¾ RAM.
    public var isSupported: Bool { OnDeviceLanguageModelSupport.mlxIsAvailable }

    /// Builds a live status for every catalog model from disk + the memory budget.
    public func statuses() -> [LocalModelStatus] {
        LLMModelCatalog.models.map { option in
            let completeness = MLXModelCatalog.completeness(for: option.id)
            return LocalModelStatus(
                option: option,
                completeness: completeness,
                sizeBytes: completeness == .absent ? nil : MLXModelCatalog.downloadedSizeBytes(option.id),
                fitsMemoryBudget: ModelCatalogService.canRun(option)
            )
        }
    }

    /// Whether the given model's weights are fully present on disk.
    public func isDownloaded(_ modelID: String) -> Bool {
        MLXModelCatalog.isDownloaded(modelID)
    }

    /// Downloads a model's weights into the managed cache, reporting progress.
    ///
    /// Uses Hub `snapshot` only — it does not load the model into MLX. A later
    /// load uses the local snapshot directory so inference never hits HTTP.
    public func download(_ modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let option = LLMModelCatalog.option(for: modelID) else {
            throw LLMServiceError.modelNotSupported(modelID)
        }
        guard ModelCatalogService.canRun(option) else {
            throw LLMServiceError.insufficientMemory(
                requiredGB: option.estimatedMemoryGB,
                availableGB: ModelCatalogService.memoryBudgetGB()
            )
        }

        AnAIOdysseyAI.ensureModelCacheDirectoryExists()
        if MLXModelCatalog.completeness(for: modelID) != .complete {
            try discardPartialDownload(modelID)
        } else {
            progress(1)
            return
        }

        let configuration = try MLXModelCatalog.configuration(for: modelID)
        _ = try await downloadModel(
            hub: MLXModelCatalog.hub,
            configuration: configuration
        ) { downloadProgress in
            Task { @MainActor in
                progress(downloadProgress.fractionCompleted)
            }
        }

        if Task.isCancelled {
            try discardPartialDownload(modelID)
            throw CancellationError()
        }

        guard MLXModelCatalog.isDownloaded(modelID) else {
            try? discardPartialDownload(modelID)
            throw LLMServiceError.generationFailed(
                "Download incomplete. Files were missing or truncated."
            )
        }
        progress(1)
    }

    /// Deletes the whole Hub repo tree (snapshot, blobs, `.incomplete`, resume data).
    public func deleteDownload(_ modelID: String) throws {
        try removeModelFiles(modelID)
    }

    public func discardPartialDownload(_ modelID: String) throws {
        try removeModelFiles(modelID)
    }

    private func removeModelFiles(_ modelID: String) throws {
        let fileManager = FileManager.default
        for url in try MLXModelCatalog.deletionURLs(for: modelID) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
