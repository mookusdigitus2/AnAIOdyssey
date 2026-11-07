// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class LocalModelDownloadPolicyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    func testHubLayoutUsesModelsOrgNameUnderDownloadBase() {
        let base = URL(fileURLWithPath: "/tmp/anaiodyssey-models")
        let url = LocalModelDownloadPolicy.localRepoLocation(
            downloadBase: base,
            repoID: LocalModelDownloadPolicy.llama1BRepoID
        )
        XCTAssertEqual(
            url.path,
            "/tmp/anaiodyssey-models/models/mlx-community/Llama-3.2-1B-Instruct-4bit"
        )
        XCTAssertEqual(
            LocalModelDownloadPolicy.encodedHubCacheDirectoryName(
                repoID: LocalModelDownloadPolicy.llama1BRepoID
            ),
            "models--mlx-community--Llama-3.2-1B-Instruct-4bit"
        )
    }

    func testDeletionURLsCoverSnapshotHubCacheAndEncodedBlobs() {
        let base = URL(fileURLWithPath: "/tmp/anaiodyssey-models")
        let extra = URL(fileURLWithPath: "/tmp/Library/Caches")
        let urls = LocalModelDownloadPolicy.deletionURLs(
            downloadBase: base,
            repoID: LocalModelDownloadPolicy.llama3BRepoID,
            extraSearchRoots: [extra]
        )
        let paths = Set(urls.map(\.path))
        XCTAssertTrue(paths.contains(
            "/tmp/anaiodyssey-models/models/mlx-community/Llama-3.2-3B-Instruct-4bit"
        ))
        XCTAssertTrue(paths.contains(
            "/tmp/anaiodyssey-models/models--mlx-community--Llama-3.2-3B-Instruct-4bit"
        ))
        XCTAssertTrue(paths.contains(
            "/tmp/Library/Caches/huggingface/hub/models--mlx-community--Llama-3.2-3B-Instruct-4bit"
        ))
        XCTAssertTrue(paths.contains(
            "/tmp/Library/Caches/models/mlx-community/Llama-3.2-3B-Instruct-4bit"
        ))
    }

    func testAbsentDirectoryIsNotDownloaded() {
        let dir = scratch.appendingPathComponent("missing")
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: LocalModelDownloadPolicy.llama1BManifest
            ),
            .absent
        )
    }

    func testConfigWithoutWeightsIsIncomplete() throws {
        let dir = scratch.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("{\"model_type\":\"llama\"}", to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .incomplete
        )
    }

    func testIncompleteMarkerBlocksComplete() throws {
        let dir = try writeCompleteSnapshot()
        try write("partial", to: dir.appendingPathComponent("model.safetensors.incomplete"))
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .incomplete
        )
    }

    func testTruncatedSafetensorsIsIncomplete() throws {
        let dir = try writeCompleteSnapshot(safetensorsBytes: 4)
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .incomplete
        )
    }

    func testIndexListingMissingShardIsIncomplete() throws {
        let dir = try writeCompleteSnapshot()
        let index = """
        {"weight_map":{"tok":"model-00001-of-00002.safetensors","lm":"model.safetensors"}}
        """
        try write(index, to: dir.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .incomplete
        )
    }

    func testCompleteSnapshotPasses() throws {
        let dir = try writeCompleteSnapshot()
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .complete
        )
    }

    func testRowNotDownloadedUsesManifestSize() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "llama3_2_3B_4bit",
                displayName: "Llama 3.2 3B (4-bit)",
                manifestSizeText: LocalModelDownloadPolicy.llama3BManifest.sizeText,
                completeness: .absent
            )
        )
        XCTAssertEqual(
            presentation.statusLine,
            "Not downloaded · \(LocalModelDownloadPolicy.llama3BManifest.sizeText)"
        )
        XCTAssertEqual(presentation.action, .download)
        XCTAssertEqual(presentation.actionTitle, "Download")
        XCTAssertFalse(presentation.showsProgress)
    }

    func testRowDownloadingShowsPercentAndCancel() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "2.1 GB",
                completeness: .incomplete,
                isDownloading: true,
                downloadProgress: 0.42
            )
        )
        XCTAssertEqual(presentation.statusLine, "Downloading 42%")
        XCTAssertEqual(presentation.action, .cancel)
        XCTAssertTrue(presentation.showsProgress)
        XCTAssertEqual(presentation.progress, 0.42)
    }

    func testRowIncompleteDownloadAgain() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "2.1 GB",
                completeness: .incomplete
            )
        )
        XCTAssertEqual(presentation.statusLine, "Download incomplete")
        XCTAssertEqual(presentation.action, .downloadAgain)
    }

    func testRowLoadingHasNoButton() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "1.2 GB",
                completeness: .complete,
                isLoading: true
            )
        )
        XCTAssertEqual(presentation.statusLine, "Loading…")
        XCTAssertNil(presentation.action)
    }

    func testRowLoadedHasCheckmarkAndDelete() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "1.2 GB",
                completeness: .complete,
                isLoaded: true
            )
        )
        XCTAssertEqual(presentation.statusLine, "Loaded")
        XCTAssertTrue(presentation.showsLoadedCheckmark)
        XCTAssertEqual(presentation.action, .delete)
        XCTAssertTrue(presentation.action?.isDestructive == true)
    }

    func testRowDownloadedDelete() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "1.2 GB",
                completeness: .complete
            )
        )
        XCTAssertEqual(presentation.statusLine, "Downloaded")
        XCTAssertEqual(presentation.action, .delete)
        XCTAssertFalse(presentation.showsLoadedCheckmark)
    }

    func testRowErrorTryAgain() {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama",
                manifestSizeText: "1.2 GB",
                completeness: .absent,
                errorMessage: "The Internet connection appears to be offline."
            )
        )
        XCTAssertTrue(presentation.statusLine.hasPrefix("Error: "))
        XCTAssertEqual(presentation.action, .tryAgain)
    }

    func testDeleteAlertCopy() {
        XCTAssertEqual(
            LocalModelDownloadPolicy.deleteAlertTitle(displayName: "Llama 3.2 1B (4-bit)"),
            "Delete Llama 3.2 1B (4-bit)?"
        )
        XCTAssertEqual(
            LocalModelDownloadPolicy.deleteAlertMessage(sizeText: "1.2 GB"),
            "This frees 1.2 GB."
        )
    }

    func testDeletedSnapshotReturnsToNotDownloaded() throws {
        let dir = try writeCompleteSnapshot()
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .complete
        )
        try FileManager.default.removeItem(at: dir)
        XCTAssertEqual(
            LocalModelDownloadPolicy.completeness(
                snapshotDirectory: dir,
                manifest: smallManifest
            ),
            .absent
        )
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: "id",
                displayName: "Llama 3.2 1B (4-bit)",
                manifestSizeText: "1.2 GB",
                completeness: .absent
            )
        )
        XCTAssertEqual(presentation.statusLine, "Not downloaded · 1.2 GB")
        XCTAssertEqual(presentation.actionTitle, "Download")
    }

    func testManifestSizesUseFileByteCounts() {
        XCTAssertFalse(LocalModelDownloadPolicy.llama1BManifest.sizeText.isEmpty)
        XCTAssertFalse(LocalModelDownloadPolicy.llama3BManifest.sizeText.isEmpty)
        XCTAssertEqual(LocalModelDownloadPolicy.snapshotGlobs, ["*.safetensors", "*.json"])
    }

    func testActionTitlesMatchUXSpec() {
        XCTAssertEqual(LocalModelRowAction.download.title, "Download")
        XCTAssertEqual(LocalModelRowAction.cancel.title, "Cancel")
        XCTAssertEqual(LocalModelRowAction.downloadAgain.title, "Download Again")
        XCTAssertEqual(LocalModelRowAction.delete.title, "Delete")
        XCTAssertEqual(LocalModelRowAction.tryAgain.title, "Try Again")
    }

    func testLocalSelectionKeysNeverUseRemoteHTTP() {
        XCTAssertFalse(
            LocalModelDownloadPolicy.shouldUseRemoteHTTP(
                selectionKey: "localMLX|llama3_2_1B_4bit"
            )
        )
        XCTAssertFalse(
            LocalModelDownloadPolicy.shouldUseRemoteHTTP(
                selectionKey: "appleFoundation|apple_foundation"
            )
        )
        XCTAssertTrue(
            LocalModelDownloadPolicy.shouldUseRemoteHTTP(
                selectionKey: "remote|openai|gpt-4o"
            )
        )
    }

    func testAgentRoutingIgnoresRemoteWhenLocalMLXIsSelected() {
        XCTAssertFalse(
            LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: "localMLX",
                activeBackendLabel: "Remote"
            )
        )
        XCTAssertFalse(
            LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: "appleFoundation",
                activeBackendLabel: "Remote"
            )
        )
        XCTAssertTrue(
            LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: "remote",
                activeBackendLabel: "Remote"
            )
        )
        XCTAssertTrue(
            LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: "auto",
                activeBackendLabel: "Remote"
            )
        )
        XCTAssertFalse(
            LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: "auto",
                activeBackendLabel: "MLX"
            )
        )
    }

    private var smallManifest: LocalModelFileManifest {
        LocalModelFileManifest(
            catalogID: "test",
            hubRepoID: "org/name",
            displayName: "Test",
            downloadSizeBytes: 100,
            requiredFiles: LocalModelDownloadPolicy.llama1BManifest.requiredFiles,
            safetensorsMinimumByteCount: 16
        )
    }

    private func writeCompleteSnapshot(safetensorsBytes: Int = 32) throws -> URL {
        let dir = scratch.appendingPathComponent("complete-\(safetensorsBytes)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(
            String(repeating: "x", count: 80),
            to: dir.appendingPathComponent("config.json")
        )
        try write(
            String(repeating: "t", count: 2_000),
            to: dir.appendingPathComponent("tokenizer.json")
        )
        try write(
            String(repeating: "c", count: 64),
            to: dir.appendingPathComponent("tokenizer_config.json")
        )
        let weights = Data(repeating: 1, count: safetensorsBytes)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent("model.safetensors").path,
                contents: weights
            )
        )
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
