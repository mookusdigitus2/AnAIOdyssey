// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import SwiftData
@testable import AnAIOdysseyCore
@testable import AIConnect
@testable import AIConnectVoice

@MainActor
final class NotionImportTests: XCTestCase {
    private var context: ModelContext!
    private var repositories: RepositoryBundle!

    override func setUpWithError() throws {
        let bundle = try TestModelContainer.makeRepositories()
        context = bundle.0
        repositories = bundle.1
    }

    override func tearDownWithError() throws {
        context = nil
        repositories = nil
    }

    func testParseNotionFilename() {
        XCTAssertEqual(
            NotionExportParser.parseFilename("CEO Dashboard 3424f043d883800b87cccec522f24033.md")?.title,
            "CEO Dashboard"
        )
        XCTAssertEqual(
            NotionExportParser.parseFilename("Projects 80b4be0d863f47308ec4474fc5af6d01_all.csv")?.kind,
            .table
        )
    }

    func testImportSampleExport() async throws {
        let exportRoot = try makeSampleExport()
        defer { try? FileManager.default.removeItem(at: exportRoot) }

        let service = NotionImportService(context: context, repositories: repositories)
        let counts = try await service.importExport(at: exportRoot)

        XCTAssertEqual(counts.pagesImported, 2)
        XCTAssertEqual(counts.tablesImported, 1)
        // "Workspace" and "Workspace/Hub" become folders mirroring the export.
        XCTAssertEqual(counts.foldersCreated, 2)

        // The directory structure is recreated as folders.
        let workspaceFolder = try repositories.folders.fetchFolder(id: "notion-folder-workspace")
        XCTAssertEqual(workspaceFolder?.name, "Workspace")
        XCTAssertNil(workspaceFolder?.parentID)
        let hubFolder = try repositories.folders.fetchFolder(id: "notion-folder-workspace/hub")
        XCTAssertEqual(hubFolder?.name, "Hub")
        XCTAssertEqual(hubFolder?.parentID, "notion-folder-workspace")

        // Pages keep clean titles and are filed into the matching folder.
        let hub = try repositories.documents.fetchDocument(id: "notion-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertNotNil(hub)
        XCTAssertEqual(hub?.title, "Hub")
        XCTAssertEqual(hub?.parentID, "notion-folder-workspace/hub")
        XCTAssertTrue(hub?.currentContent.contains("> 📊 Studio hub") ?? false)
        XCTAssertTrue(hub?.currentContent.contains("[Child page](#notion-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)") ?? false)

        let child = try repositories.documents.fetchDocument(id: "notion-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(child?.title, "Child page")
        XCTAssertEqual(child?.parentID, "notion-folder-workspace/hub")

        let table = try repositories.documents.fetchDocument(id: "notion-cccccccccccccccccccccccccccccccc")
        XCTAssertEqual(table?.title, "People")
        XCTAssertEqual(table?.parentID, "notion-folder-workspace/hub")
        XCTAssertTrue(table?.currentContent.contains("| Name | Role |") ?? false)
    }

    func testReimportSkipsExistingDocuments() async throws {
        let exportRoot = try makeSampleExport()
        defer { try? FileManager.default.removeItem(at: exportRoot) }

        let service = NotionImportService(context: context, repositories: repositories)
        _ = try await service.importExport(at: exportRoot)
        let second = try await service.importExport(at: exportRoot)

        XCTAssertEqual(second.pagesSkipped, 2)
        XCTAssertEqual(second.tablesSkipped, 1)
        XCTAssertEqual(second.totalImported, 0)
        // Folders are reused on re-import, not duplicated.
        XCTAssertEqual(second.foldersCreated, 0)
    }

    private func makeSampleExport() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notion-fixture-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        let hub = workspace.appendingPathComponent("Hub", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let hubPage = """
        # Hub

        <aside>
        📊 Studio hub
        </aside>

        [Child page](Hub/Child%20page%20bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md)
        """
        try hubPage.write(
            to: hub.appendingPathComponent("Hub aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md"),
            atomically: true,
            encoding: .utf8
        )

        let childPage = "# Child page\n\nDetails here."
        try childPage.write(
            to: hub.appendingPathComponent("Child page bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md"),
            atomically: true,
            encoding: .utf8
        )

        let csv = """
        Name,Role
        Alex,Owner
        Teddy,Guest
        """
        try csv.write(
            to: hub.appendingPathComponent("People cccccccccccccccccccccccccccccccc_all.csv"),
            atomically: true,
            encoding: .utf8
        )

        return root
    }
}
