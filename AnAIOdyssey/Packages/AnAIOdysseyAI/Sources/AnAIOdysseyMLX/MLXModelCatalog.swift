// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import AnAIOdysseyAI
import AIModelOptions

/// Bridges the portable `LLMModelCatalog` ids to concrete MLX `ModelConfiguration`s
/// and owns the single on-disk location where weights are stored and managed.
///
/// Both `MLXLLMService` (loading) and `MLXModelManager` (download/delete/inspect)
/// go through here so the model id → repo → directory mapping is defined once.
enum MLXModelCatalog {
    /// Where downloaded weights live: `Application Support/AnAIOdyssey/models`.
    ///
    /// Pin Hub snapshots under Application Support so we can enumerate and
    /// delete the whole repo tree. Load uses a directory configuration so Hub
    /// is not contacted after files are complete.
    static let hub = HubApi(downloadBase: AnAIOdysseyAI.modelCacheDirectory)

    /// Resolves a catalog id to its MLX Hub configuration, throwing for unknown ids.
    static func configuration(for modelID: String) throws -> ModelConfiguration {
        switch modelID {
        case LocalModelDownloadPolicy.llama1BCatalogID:
            return LLMRegistry.llama3_2_1B_4bit
        case LocalModelDownloadPolicy.llama3BCatalogID:
            return LLMRegistry.llama3_2_3B_4bit
        default:
            throw LLMServiceError.modelNotSupported(modelID)
        }
    }

    /// Load configuration that points at the local snapshot only — no Hub HTTP.
    static func localLoadConfiguration(for modelID: String) throws -> ModelConfiguration {
        let directory = try modelDirectory(for: modelID)
        let hubConfig = try configuration(for: modelID)
        return ModelConfiguration(
            directory: directory,
            tokenizerId: hubConfig.tokenizerId,
            overrideTokenizer: hubConfig.overrideTokenizer,
            defaultPrompt: hubConfig.defaultPrompt,
            extraEOSTokens: hubConfig.extraEOSTokens
        )
    }

    static func hubRepoID(for modelID: String) throws -> String {
        guard let repoID = LocalModelDownloadPolicy.hubRepoID(forCatalogID: modelID) else {
            throw LLMServiceError.modelNotSupported(modelID)
        }
        return repoID
    }

    /// On-disk directory where the model's snapshot is materialized under `hub`.
    static func modelDirectory(for modelID: String) throws -> URL {
        let repoID = try hubRepoID(for: modelID)
        return LocalModelDownloadPolicy.localRepoLocation(
            downloadBase: AnAIOdysseyAI.modelCacheDirectory,
            repoID: repoID
        )
    }

    static func completeness(for modelID: String) -> LocalModelDiskCompleteness {
        guard let manifest = LocalModelDownloadPolicy.manifest(forCatalogID: modelID),
              let directory = try? modelDirectory(for: modelID)
        else {
            return .absent
        }
        return LocalModelDownloadPolicy.completeness(
            snapshotDirectory: directory,
            manifest: manifest
        )
    }

    /// Whether a model's weights are fully present on disk.
    static func isDownloaded(_ modelID: String) -> Bool {
        completeness(for: modelID) == .complete
    }

    /// Total size in bytes of a model's downloaded files, or `nil` if nothing is present.
    static func downloadedSizeBytes(_ modelID: String) -> Int64? {
        guard let directory = try? modelDirectory(for: modelID),
              FileManager.default.fileExists(atPath: directory.path)
        else {
            return nil
        }
        let size = directorySize(at: directory)
        return size > 0 ? size : nil
    }

    static func deletionURLs(for modelID: String) throws -> [URL] {
        let repoID = try hubRepoID(for: modelID)
        return LocalModelDownloadPolicy.deletionURLs(
            downloadBase: AnAIOdysseyAI.modelCacheDirectory,
            repoID: repoID,
            extraSearchRoots: LocalModelDownloadPolicy.defaultExtraCacheRoots()
        )
    }

    /// Recursively sums regular-file sizes under a directory (best-effort).
    private static func directorySize(at directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
