// SPDX-License-Identifier: MIT
import Foundation

/// On-disk completeness of one local MLX catalog model.
public enum LocalModelDiskCompleteness: String, Sendable, Equatable, Hashable {
    /// No files for this repo under the download base.
    case absent
    /// Some files exist, but required weights/tokenizer files are missing, empty, or still `.incomplete`.
    case incomplete
    /// Required files are present with non-truncated sizes and no leftover partials.
    case complete
}

/// One required snapshot file and the smallest size we accept as "not truncated".
public struct LocalModelManifestFile: Equatable, Sendable {
    public var relativePath: String
    public var minimumByteCount: Int64

    public init(relativePath: String, minimumByteCount: Int64) {
        self.relativePath = relativePath
        self.minimumByteCount = minimumByteCount
    }
}

/// Hugging Face snapshot expected for one catalog model.
public struct LocalModelFileManifest: Equatable, Sendable {
    public var catalogID: String
    public var hubRepoID: String
    public var displayName: String
    public var downloadSizeBytes: Int64
    public var requiredFiles: [LocalModelManifestFile]
    public var safetensorsMinimumByteCount: Int64

    public init(
        catalogID: String,
        hubRepoID: String,
        displayName: String,
        downloadSizeBytes: Int64,
        requiredFiles: [LocalModelManifestFile],
        safetensorsMinimumByteCount: Int64
    ) {
        self.catalogID = catalogID
        self.hubRepoID = hubRepoID
        self.displayName = displayName
        self.downloadSizeBytes = downloadSizeBytes
        self.requiredFiles = requiredFiles
        self.safetensorsMinimumByteCount = safetensorsMinimumByteCount
    }

    public var sizeText: String {
        LocalModelDownloadPolicy.sizeText(bytes: downloadSizeBytes)
    }
}

/// Button on a local-model Settings row. `nil` action means no button (Loading…).
public enum LocalModelRowAction: String, Sendable, Equatable {
    case download
    case cancel
    case downloadAgain
    case delete
    case tryAgain

    public var title: String {
        switch self {
        case .download: "Download"
        case .cancel: "Cancel"
        case .downloadAgain: "Download Again"
        case .delete: "Delete"
        case .tryAgain: "Try Again"
        }
    }

    public var isDestructive: Bool { self == .delete }
}

/// Inputs the Settings row needs to pick a status line and button.
public struct LocalModelRowInput: Equatable, Sendable {
    public var catalogID: String
    public var displayName: String
    public var manifestSizeText: String
    public var completeness: LocalModelDiskCompleteness
    public var downloadedSizeBytes: Int64?
    public var isDownloading: Bool
    public var downloadProgress: Double?
    public var isLoading: Bool
    public var isLoaded: Bool
    public var errorMessage: String?

    public init(
        catalogID: String,
        displayName: String,
        manifestSizeText: String,
        completeness: LocalModelDiskCompleteness,
        downloadedSizeBytes: Int64? = nil,
        isDownloading: Bool = false,
        downloadProgress: Double? = nil,
        isLoading: Bool = false,
        isLoaded: Bool = false,
        errorMessage: String? = nil
    ) {
        self.catalogID = catalogID
        self.displayName = displayName
        self.manifestSizeText = manifestSizeText
        self.completeness = completeness
        self.downloadedSizeBytes = downloadedSizeBytes
        self.isDownloading = isDownloading
        self.downloadProgress = downloadProgress
        self.isLoading = isLoading
        self.isLoaded = isLoaded
        self.errorMessage = errorMessage
    }
}

/// One status line plus optional button for a local-model row.
public struct LocalModelRowPresentation: Equatable, Sendable {
    public var statusLine: String
    public var showsProgress: Bool
    public var progress: Double?
    public var showsLoadedCheckmark: Bool
    public var action: LocalModelRowAction?

    public var actionTitle: String? { action?.title }

    public init(
        statusLine: String,
        showsProgress: Bool = false,
        progress: Double? = nil,
        showsLoadedCheckmark: Bool = false,
        action: LocalModelRowAction? = nil
    ) {
        self.statusLine = statusLine
        self.showsProgress = showsProgress
        self.progress = progress
        self.showsLoadedCheckmark = showsLoadedCheckmark
        self.action = action
    }
}

/// Portable Hugging Face layout, completeness, delete paths, row copy, and
/// local-vs-remote routing. Kept free of MLX/Hub so Linux tests can run it.
public enum LocalModelDownloadPolicy {
    public static let llama1BCatalogID = "llama3_2_1B_4bit"
    public static let llama3BCatalogID = "llama3_2_3B_4bit"
    public static let llama1BRepoID = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    public static let llama3BRepoID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    /// Hub `snapshot(matching:)` globs used by mlx-swift-lm `downloadModel`.
    public static let snapshotGlobs = ["*.safetensors", "*.json"]

    public static let llama1BManifest = LocalModelFileManifest(
        catalogID: llama1BCatalogID,
        hubRepoID: llama1BRepoID,
        displayName: "Llama 3.2 1B (4-bit)",
        downloadSizeBytes: 1_288_490_189,
        requiredFiles: defaultRequiredFiles,
        safetensorsMinimumByteCount: 50_000_000
    )

    public static let llama3BManifest = LocalModelFileManifest(
        catalogID: llama3BCatalogID,
        hubRepoID: llama3BRepoID,
        displayName: "Llama 3.2 3B (4-bit)",
        downloadSizeBytes: 2_254_833_664,
        requiredFiles: defaultRequiredFiles,
        safetensorsMinimumByteCount: 100_000_000
    )

    public static let manifests: [LocalModelFileManifest] = [llama1BManifest, llama3BManifest]

    private static let defaultRequiredFiles: [LocalModelManifestFile] = [
        LocalModelManifestFile(relativePath: "config.json", minimumByteCount: 64),
        LocalModelManifestFile(relativePath: "tokenizer.json", minimumByteCount: 1_024),
        LocalModelManifestFile(relativePath: "tokenizer_config.json", minimumByteCount: 32),
    ]

    public static func manifest(forCatalogID catalogID: String) -> LocalModelFileManifest? {
        manifests.first { $0.catalogID == catalogID }
    }

    public static func hubRepoID(forCatalogID catalogID: String) -> String? {
        manifest(forCatalogID: catalogID)?.hubRepoID
    }

    public static func sizeText(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Hub layout

    /// `downloadBase/models/<org>/<name>` — matches `HubApi.localRepoLocation`.
    public static func localRepoLocation(downloadBase: URL, repoID: String) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    /// Hugging Face content-addressed cache folder `models--org--name`.
    public static func encodedHubCacheDirectoryName(repoID: String) -> String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    /// Every directory that may hold this model's snapshot, blobs, `.incomplete`
    /// files, or URLSession resume metadata. Delete them all so the next download
    /// cannot resume a leftover slice.
    public static func deletionURLs(
        downloadBase: URL,
        repoID: String,
        extraSearchRoots: [URL] = []
    ) -> [URL] {
        let encoded = encodedHubCacheDirectoryName(repoID: repoID)
        var urls = [
            localRepoLocation(downloadBase: downloadBase, repoID: repoID),
            downloadBase.appendingPathComponent(encoded, isDirectory: true),
            downloadBase.appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent(encoded, isDirectory: true),
            downloadBase.appendingPathComponent("HubCache", isDirectory: true)
                .appendingPathComponent(encoded, isDirectory: true),
        ]
        for root in extraSearchRoots {
            urls.append(root.appendingPathComponent(encoded, isDirectory: true))
            urls.append(
                root.appendingPathComponent("hub", isDirectory: true)
                    .appendingPathComponent(encoded, isDirectory: true)
            )
            urls.append(
                root.appendingPathComponent("huggingface", isDirectory: true)
                    .appendingPathComponent("hub", isDirectory: true)
                    .appendingPathComponent(encoded, isDirectory: true)
            )
            urls.append(localRepoLocation(downloadBase: root, repoID: repoID))
        }
        return uniqueURLs(urls)
    }

    public static func defaultExtraCacheRoots() -> [URL] {
        var roots: [URL] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches)
            roots.append(caches.appendingPathComponent("huggingface", isDirectory: true))
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            roots.append(support.appendingPathComponent("huggingface", isDirectory: true))
        }
        return roots
    }

    // MARK: Completeness

    public static func completeness(
        snapshotDirectory: URL,
        manifest: LocalModelFileManifest,
        fileManager: FileManager = .default
    ) -> LocalModelDiskCompleteness {
        completeness(
            repoDirectory: snapshotDirectory,
            snapshotDirectory: snapshotDirectory,
            manifest: manifest,
            fileManager: fileManager
        )
    }

    public static func completeness(
        repoDirectory: URL,
        snapshotDirectory: URL,
        manifest: LocalModelFileManifest,
        fileManager: FileManager = .default
    ) -> LocalModelDiskCompleteness {
        let repoExists = directoryHasAnyRegularFile(repoDirectory, fileManager: fileManager)
        let snapshotExists = fileManager.fileExists(atPath: snapshotDirectory.path)
        if !repoExists && !snapshotExists {
            return .absent
        }
        if containsIncompleteMarker(at: repoDirectory, fileManager: fileManager)
            || containsIncompleteMarker(at: snapshotDirectory, fileManager: fileManager)
        {
            return .incomplete
        }
        for file in manifest.requiredFiles {
            let url = snapshotDirectory.appendingPathComponent(file.relativePath)
            guard fileSize(at: url, fileManager: fileManager) >= file.minimumByteCount else {
                return repoExists || snapshotExists ? .incomplete : .absent
            }
        }
        let shards = safetensorFiles(in: snapshotDirectory, fileManager: fileManager)
        guard shards.contains(where: { $0.size >= manifest.safetensorsMinimumByteCount }) else {
            return .incomplete
        }
        if let missing = missingIndexShards(
            snapshotDirectory: snapshotDirectory,
            fileManager: fileManager
        ) {
            return missing ? .incomplete : .complete
        }
        return .complete
    }

    /// `true` if the safetensors index lists a shard that is missing or empty.
    /// `nil` when there is no index (single-file models).
    public static func missingIndexShards(
        snapshotDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool? {
        let indexURL = snapshotDirectory.appendingPathComponent("model.safetensors.index.json")
        guard fileManager.fileExists(atPath: indexURL.path),
              let data = fileManager.contents(atPath: indexURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let weightMap = json["weight_map"] as? [String: String] ?? [:]
        let names = Set(weightMap.values)
        guard !names.isEmpty else { return nil }
        for name in names {
            let url = snapshotDirectory.appendingPathComponent(name)
            if fileSize(at: url, fileManager: fileManager) <= 0 {
                return true
            }
        }
        return false
    }

    // MARK: Row presentation

    public static func present(_ input: LocalModelRowInput) -> LocalModelRowPresentation {
        if input.isDownloading {
            let percent = Int(((input.downloadProgress ?? 0) * 100).rounded(.down))
            return LocalModelRowPresentation(
                statusLine: "Downloading \(percent)%",
                showsProgress: true,
                progress: input.downloadProgress,
                action: .cancel
            )
        }
        if input.isLoading {
            return LocalModelRowPresentation(statusLine: "Loading…")
        }
        if let message = input.errorMessage, !message.isEmpty {
            return LocalModelRowPresentation(
                statusLine: "Error: \(shortError(message))",
                action: .tryAgain
            )
        }
        if input.isLoaded {
            return LocalModelRowPresentation(
                statusLine: "Loaded",
                showsLoadedCheckmark: true,
                action: .delete
            )
        }
        switch input.completeness {
        case .complete:
            return LocalModelRowPresentation(statusLine: "Downloaded", action: .delete)
        case .incomplete:
            return LocalModelRowPresentation(
                statusLine: "Download incomplete",
                action: .downloadAgain
            )
        case .absent:
            return LocalModelRowPresentation(
                statusLine: "Not downloaded · \(input.manifestSizeText)",
                action: .download
            )
        }
    }

    public static func deleteAlertTitle(displayName: String) -> String {
        "Delete \(displayName)?"
    }

    public static func deleteAlertMessage(sizeText: String) -> String {
        "This frees \(sizeText)."
    }

    public static func shortError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(77)) + "…"
    }

    // MARK: Routing

    /// `localMLX|…` and `appleFoundation|…` must never be sent to an HTTP backend.
    public static func shouldUseRemoteHTTP(selectionKey: String) -> Bool {
        selectionKey.split(separator: "|").first.map(String.init) == "remote"
    }

    /// Agent structured-tool rounds go to `RemoteLLMService` only for a remote backend.
    public static func shouldUseRemoteHTTPAgent(
        backendRawValue: String,
        activeBackendLabel: String
    ) -> Bool {
        switch backendRawValue {
        case "remote":
            return true
        case "localMLX", "appleFoundation":
            return false
        case "auto":
            return activeBackendLabel == "Remote"
        default:
            return false
        }
    }

    // MARK: Helpers

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func containsIncompleteMarker(at directory: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey]
              )
        else {
            return false
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".incomplete")
                || name.hasSuffix(".download")
                || name == "resume.plist"
                || name.hasSuffix(".resume")
            {
                return true
            }
        }
        return false
    }

    private static func directoryHasAnyRegularFile(_ directory: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey]
              )
        else {
            return false
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private static func safetensorFiles(
        in directory: URL,
        fileManager: FileManager
    ) -> [(url: URL, size: Int64)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".safetensors") else { return nil }
            let url = directory.appendingPathComponent(name)
            return (url, fileSize(at: url, fileManager: fileManager))
        }
    }
}
