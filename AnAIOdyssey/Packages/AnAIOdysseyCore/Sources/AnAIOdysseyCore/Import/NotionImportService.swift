// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftData

/// Imports pages and database tables from a Notion Markdown & CSV export folder.
///
/// Each Notion page/table becomes a `Document`, keyed by a deterministic
/// `notion-<id>` so re-imports are idempotent and internal links can be
/// rewritten to in-app anchors. Heavy lifting (scanning, Markdown/CSV
/// normalization, unzip) lives in the `NotionImport*` helpers; this service
/// orchestrates them and persists the results.
@MainActor
public final class NotionImportService {
    /// Callback reporting the current stage and overall progress in `0...1`.
    public typealias ProgressHandler = (_ stage: String, _ fraction: Double) -> Void

    /// Destination SwiftData context for inserted documents.
    private let context: ModelContext
    /// Repositories used for existence checks (skip logic) and the final save.
    private let repositories: RepositoryBundle

    /// Injects the destination context and repositories.
    public init(context: ModelContext, repositories: RepositoryBundle) {
        self.context = context
        self.repositories = repositories
    }

    /// Imports an entire Notion export at `url` (folder or zip), reporting
    /// progress and returning the import tally.
    ///
    /// Resolves/unzips the export, scans for entries, then imports each as a page
    /// or table, committing once at the end. Throws `emptyExport` if nothing
    /// importable is found.
    public func importExport(at url: URL, progress: ProgressHandler? = nil) async throws -> NotionImportCounts {
        // Acquire (and guarantee release of) security-scoped access for the
        // user-selected file/folder.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Resolve to a readable root (unzipping if needed); cleanup runs on exit.
        let prepared = try NotionExportArchive.prepareRootURL(from: url)
        defer { prepared.cleanup() }

        progress?("Scanning export", 0.05)

        // Discover importable entries; an empty export is an error.
        let entries = try NotionExportParser.scanExport(at: prepared.rootURL)
        guard !entries.isEmpty else {
            throw NotionImportError.emptyExport
        }

        // Precompute Notion ID → in-app document ID so internal links can be
        // rewritten to anchors during page processing.
        let linkTargets = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.notionID, NotionExportParser.documentID(for: $0.notionID)) }
        )

        var counts = NotionImportCounts()
        // Maps an export-relative directory path to the `Folder.id` mirroring it,
        // populated lazily so each directory becomes a folder exactly once.
        var folderCache: [String: String] = [:]
        let total = entries.count

        // Import each entry, advancing progress across the 0.1...0.95 band.
        for (index, entry) in entries.enumerated() {
            let fraction = 0.1 + (0.85 * Double(index + 1) / Double(total))
            progress?("Importing \(entry.title)", fraction)

            // Mirror the containing directory chain as folders, then file the item
            // into the matching folder (nil = export root).
            let containingDir = (entry.relativePath as NSString).deletingLastPathComponent
            let parentID = try ensureFolderID(forRelativeDir: containingDir, cache: &folderCache, counts: &counts)

            switch entry.kind {
            case .page:
                try importPage(entry, parentID: parentID, linkTargets: linkTargets, counts: &counts)
            case .table:
                try importTable(entry, parentID: parentID, counts: &counts)
            }
        }

        // Single commit for the whole batch (documents + folders share the context).
        try repositories.documents.save()
        progress?("Complete", 1.0)
        return counts
    }

    /// Ensures a `Folder` exists for `dir` (and every ancestor), returning the
    /// leaf folder's id, or `nil` for the export root.
    ///
    /// Folder ids are deterministic (`notion-folder-<relative-path>`) so
    /// re-imports reuse the same folders instead of duplicating them; names have
    /// any Notion ID suffix stripped.
    private func ensureFolderID(
        forRelativeDir dir: String,
        cache: inout [String: String],
        counts: inout NotionImportCounts
    ) throws -> String? {
        // Normalize and treat the empty path as the root.
        let trimmed = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return nil }
        if let cached = cache[trimmed] { return cached }

        // Recurse to guarantee the parent folder exists first.
        let components = trimmed.split(separator: "/").map(String.init)
        let parentDir = components.dropLast().joined(separator: "/")
        let parentID = try ensureFolderID(forRelativeDir: parentDir, cache: &cache, counts: &counts)

        let name = NotionExportParser.strippedTitle(components.last ?? trimmed)
        let deterministicID = "notion-folder-\(trimmed.lowercased())"

        // Reuse an existing folder (idempotent re-import) or create a new one.
        if let existing = try repositories.folders.fetchFolder(id: deterministicID) {
            cache[trimmed] = existing.id
            return existing.id
        }
        let folder = Folder(id: deterministicID, name: name, parentID: parentID, kind: .documents)
        context.insert(folder)
        counts.foldersCreated += 1
        cache[trimmed] = deterministicID
        return deterministicID
    }

    /// Imports one Markdown page as a `Document`, normalizing its content and
    /// rewriting internal links. Skips pages that already exist.
    private func importPage(
        _ entry: NotionExportEntry,
        parentID: String?,
        linkTargets: [String: String],
        counts: inout NotionImportCounts
    ) throws {
        // Idempotency: skip if this page was already imported.
        let documentID = NotionExportParser.documentID(for: entry.notionID)
        if try repositories.documents.fetchDocument(id: documentID) != nil {
            counts.pagesSkipped += 1
            return
        }

        // Read and normalize the page's Markdown.
        let raw = try String(contentsOf: entry.url, encoding: .utf8)
        let content = NotionMarkdownProcessor.processPageContent(raw, linkTargets: linkTargets)

        // Create the document (filed in its folder) and record an initial
        // "import" version snapshot. The folder hierarchy carries the structure,
        // so the title stays clean (no breadcrumb prefix).
        let document = Document(
            id: documentID,
            parentID: parentID,
            title: entry.title,
            language: "markdown",
            currentContent: content,
            versionCount: 0
        )
        _ = document.saveContent(content, summary: "Imported from Notion", source: "import")
        context.insert(document)
        counts.pagesImported += 1
    }

    /// Imports one CSV database table as a `Document`, rendered to a Markdown
    /// table. Skips tables that already exist.
    private func importTable(_ entry: NotionExportEntry, parentID: String?, counts: inout NotionImportCounts) throws {
        // Idempotency: skip if this table was already imported.
        let documentID = NotionExportParser.documentID(for: entry.notionID)
        if try repositories.documents.fetchDocument(id: documentID) != nil {
            counts.tablesSkipped += 1
            return
        }

        // Read the CSV and render it as a Markdown table.
        let raw = try String(contentsOf: entry.url, encoding: .utf8)
        let content = NotionMarkdownProcessor.csvToMarkdown(raw, title: entry.title)

        // Create the document (filed in its folder) and record an initial
        // "import" version snapshot.
        let document = Document(
            id: documentID,
            parentID: parentID,
            title: entry.title,
            language: "markdown",
            currentContent: content,
            versionCount: 0
        )
        _ = document.saveContent(content, summary: "Imported Notion database table", source: "import")
        context.insert(document)
        counts.tablesImported += 1
    }
}
