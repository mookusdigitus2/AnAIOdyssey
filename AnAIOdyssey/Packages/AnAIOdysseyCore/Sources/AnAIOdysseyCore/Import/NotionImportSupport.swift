// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Tally of Notion pages/tables imported vs. skipped, returned by
/// `NotionImportService`. "Skipped" means already present (imports are
/// idempotent).
public struct NotionImportCounts: Sendable, Equatable {
    /// Per-kind imported/skipped counters.
    public var pagesImported = 0
    public var pagesSkipped = 0
    public var tablesImported = 0
    public var tablesSkipped = 0
    /// Folders created to mirror the export's directory structure.
    public var foldersCreated = 0

    /// Total items newly imported.
    public var totalImported: Int { pagesImported + tablesImported }
    /// Total items skipped (already present).
    public var totalSkipped: Int { pagesSkipped + tablesSkipped }

    /// Human-readable summary of the import outcome.
    public var summary: String {
        """
        Imported \(totalImported) Notion item(s) (\(totalSkipped) skipped) into \(foldersCreated) folder(s).
        Pages: \(pagesImported)/\(pagesSkipped), Tables: \(tablesImported)/\(tablesSkipped).
        """
    }
}

/// Errors thrown while importing a Notion Markdown & CSV export.
public enum NotionImportError: Error, LocalizedError {
    /// The export folder couldn't be read (permissions / not a directory).
    case inaccessibleExport
    /// The export contained no recognizable pages or tables.
    case emptyExport
    /// Unzipping a `.zip` export failed.
    case unzipFailed(String)
    /// A specific file within the export couldn't be read.
    case unreadableFile(String)

    /// User-facing description for surfacing in alerts.
    public var errorDescription: String? {
        switch self {
        case .inaccessibleExport:
            "Could not read the selected Notion export folder."
        case .emptyExport:
            "The export folder does not contain any Notion pages or database tables."
        case .unzipFailed(let message):
            "Could not unzip the Notion export: \(message)"
        case .unreadableFile(let path):
            "Could not read file: \(path)"
        }
    }
}

/// One importable item discovered in a Notion export: a Markdown page or a CSV
/// database table, with the metadata parsed from its filename/path.
struct NotionExportEntry: Sendable, Equatable {
    /// Whether the entry is a page or a database table.
    enum Kind: Sendable, Equatable {
        case page
        case table
    }

    /// File location on disk.
    let url: URL
    /// Path relative to the export root (used for sorting/breadcrumbs).
    let relativePath: String
    /// Human title parsed from the filename (sans Notion ID suffix).
    let title: String
    /// The 32-hex Notion ID extracted from the filename.
    let notionID: String
    /// Page vs. table.
    let kind: Kind
    /// "Folder / Folder" trail derived from the containing directories.
    let breadcrumb: String
}

/// Parses Notion export filenames/paths into structured `NotionExportEntry`s.
///
/// Notion exports encode a 32-char hex ID as a suffix on each file/folder name
/// (e.g. `My Page abcdef...0123.md`); this strips those to recover clean titles
/// and stable IDs, and maps tables (`*_all.csv`) vs. pages (`*.md`).
enum NotionExportParser {
    /// Matches the trailing " <32 hex chars>" Notion ID suffix.
    private static let idSuffixRegex = try! NSRegularExpression(pattern: #"\s([0-9a-f]{32})$"#)

    /// Classifies a filename as a page/table and extracts its title + Notion ID,
    /// or returns nil if it isn't a recognized export file.
    static func parseFilename(_ filename: String) -> (title: String, notionID: String, kind: NotionExportEntry.Kind)? {
        // Database tables are exported as "<name>_all.csv".
        if filename.hasSuffix("_all.csv") {
            let stem = String(filename.dropLast("_all.csv".count))
            guard let parsed = parseTitleAndID(stem) else { return nil }
            return (parsed.title, parsed.id, .table)
        }

        // Pages are exported as "<name>.md".
        if filename.hasSuffix(".md") {
            let stem = String(filename.dropLast(3))
            guard let parsed = parseTitleAndID(stem) else { return nil }
            return (parsed.title, parsed.id, .page)
        }

        return nil
    }

    /// Maps a Notion ID to the stable `Document.id` used on import, so re-imports
    /// and internal links resolve to the same document.
    static func documentID(for notionID: String) -> String {
        "notion-\(notionID)"
    }

    /// Returns `name` with any trailing Notion ID suffix removed (or `name`
    /// unchanged when there is none). Used to clean directory/folder names.
    static func strippedTitle(_ name: String) -> String {
        parseTitleAndID(name)?.title ?? name
    }

    /// Recursively scans an export folder and returns every importable entry,
    /// sorted by path. Throws if the folder can't be enumerated.
    static func scanExport(at rootURL: URL) throws -> [NotionExportEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NotionImportError.inaccessibleExport
        }

        var entries: [NotionExportEntry] = []
        for case let fileURL as URL in enumerator {
            // Only consider regular files that parse as a page/table.
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let filename = fileURL.lastPathComponent
            guard let parsed = parseFilename(filename) else { continue }

            // Compute the path relative to the root, guarding against files that
            // escape it via symlinks.
            let rootPath = rootURL.resolvingSymlinksInPath().path
            let filePath = fileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            // Build a human breadcrumb from the containing folders, stripping the
            // Notion ID suffix from each folder name.
            let directory = (relativePath as NSString).deletingLastPathComponent
            let breadcrumb = directory
                .split(separator: "/")
                .map { folderName in
                    parseTitleAndID(String(folderName))?.title ?? String(folderName)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")

            entries.append(
                NotionExportEntry(
                    url: fileURL,
                    relativePath: relativePath,
                    title: parsed.title,
                    notionID: parsed.notionID,
                    kind: parsed.kind,
                    breadcrumb: breadcrumb
                )
            )
        }

        // Stable, human-friendly ordering by path.
        return entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Builds the document title shown to the user, prefixing the breadcrumb and
    /// tagging tables with "(table)".
    static func displayTitle(for entry: NotionExportEntry) -> String {
        switch entry.kind {
        case .page:
            if entry.breadcrumb.isEmpty {
                return entry.title
            }
            return "\(entry.breadcrumb) / \(entry.title)"
        case .table:
            let prefix = entry.breadcrumb.isEmpty ? "" : "\(entry.breadcrumb) / "
            return "\(prefix)\(entry.title) (table)"
        }
    }

    /// Splits a "Title <32-hex-id>" stem into its title and ID, or nil if the
    /// trailing ID suffix isn't present.
    private static func parseTitleAndID(_ value: String) -> (title: String, id: String)? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = idSuffixRegex.firstMatch(in: value, range: range),
              match.numberOfRanges == 2,
              let idRange = Range(match.range(at: 1), in: value),
              let fullRange = Range(match.range, in: value) else {
            return nil
        }
        // Title is everything before the matched " <id>" suffix.
        let title = String(value[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let id = String(value[idRange])
        guard !title.isEmpty, id.count == 32 else { return nil }
        return (title, id)
    }
}

/// Cleans up Notion-exported Markdown and converts CSV tables to Markdown.
///
/// Notion's export uses a few non-standard constructs (`<aside>` callouts,
/// percent-encoded internal `.md` links) that this normalizes into portable
/// Markdown, and rewrites cross-page links to in-app document anchors.
enum NotionMarkdownProcessor {
    /// Normalizes a page's raw Markdown: unify newlines, convert asides to
    /// blockquotes, and rewrite internal links to in-app anchors.
    static func processPageContent(
        _ raw: String,
        linkTargets: [String: String]
    ) -> String {
        var content = raw.replacingOccurrences(of: "\r\n", with: "\n")
        content = convertAsidesToBlockquotes(content)
        content = rewriteInternalLinks(content, linkTargets: linkTargets)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders a Notion table CSV as a Markdown table under a `# title` heading,
    /// or an "empty table" placeholder when there are no rows.
    static func csvToMarkdown(_ csv: String, title: String) -> String {
        let rows = parseCSV(csv)
        guard !rows.isEmpty else {
            return "# \(title)\n\n_(Empty table)_"
        }

        // First CSV row is the header; emit it plus the Markdown separator row,
        // then each body row (padded to the header width).
        let header = rows[0]
        let bodyRows = rows.dropFirst()
        var lines = ["# \(title)", ""]
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("| " + header.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in bodyRows {
            let cells = padRow(row, to: header.count)
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// Converts Notion `<aside>...</aside>` callouts into Markdown blockquotes,
    /// leaving text without asides untouched.
    private static func convertAsidesToBlockquotes(_ text: String) -> String {
        guard text.contains("<aside>") else { return text }

        // Walk the string, copying text outside asides verbatim and quoting the
        // contents of each aside.
        var result = ""
        var remainder = text[...]
        while let start = remainder.range(of: "<aside>") {
            result += remainder[..<start.lowerBound]
            remainder = remainder[start.upperBound...]
            if let end = remainder.range(of: "</aside>") {
                // Quote each line of the aside's inner content as a blockquote.
                let inner = remainder[..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.isEmpty {
                    result += "\n"
                } else {
                    let quoted = inner
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> \($0)" }
                        .joined(separator: "\n")
                    result += quoted + "\n\n"
                }
                remainder = remainder[end.upperBound...]
            } else {
                // Unterminated opening tag: emit it literally and stop.
                result += "<aside>"
                break
            }
        }
        result += remainder
        return result
    }

    /// Matches Markdown links pointing at a local `.md` file: `[label](path.md)`.
    private static let markdownLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)]+\.md)\)"#
    )

    /// Rewrites internal page links (`[x](Some Page <id>.md)`) to in-app anchors
    /// (`[x](#notion-<id>)`) using `linkTargets` (Notion ID → document ID).
    private static func rewriteInternalLinks(_ text: String, linkTargets: [String: String]) -> String {
        guard text.contains(".md") else { return text }

        // Rewrite matches back-to-front so earlier ranges stay valid as we edit.
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = markdownLinkRegex.matches(in: text, range: range).reversed()
        var result = text
        for match in matches {
            guard match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: result),
                  let targetRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }
            let label = String(result[labelRange])
            let target = String(result[targetRange])
            // Decode percent-encoding and reduce to the filename to recover the
            // Notion ID; only rewrite links whose target we actually imported.
            let decoded = target.removingPercentEncoding ?? target
            let filename = (decoded as NSString).lastPathComponent

            if let parsed = NotionExportParser.parseFilename(filename),
               let documentID = linkTargets[parsed.notionID] {
                result.replaceSubrange(fullRange, with: "[\(label)](#\(documentID))")
            }
        }
        return result
    }

    /// Minimal RFC-4180-ish CSV parser handling quoted fields and embedded
    /// newlines/commas; trims whitespace and drops fully-empty rows.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        for char in normalized {
            switch char {
            case "\"":
                // Toggle in/out of a quoted field; quotes themselves are dropped.
                inQuotes.toggle()
            case "," where !inQuotes:
                // Unquoted comma ends the current field.
                row.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            case "\n" where !inQuotes:
                // Unquoted newline ends the field and the row (skip blank rows).
                row.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
                if !row.allSatisfy(\.isEmpty) {
                    rows.append(row)
                }
                row = []
            default:
                field.append(char)
            }
        }

        // Flush the trailing field/row if the input didn't end with a newline.
        row.append(field.trimmingCharacters(in: .whitespaces))
        if !row.allSatisfy(\.isEmpty) {
            rows.append(row)
        }
        return rows
    }

    /// Pads (or truncates) a row to exactly `count` columns so it lines up with
    /// the header in the rendered Markdown table.
    private static func padRow(_ row: [String], to count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}

/// Resolves a user-selected Notion export (folder or `.zip`) to a readable root
/// directory, handling unzip and the common "single wrapper folder" layout.
enum NotionExportArchive {
    /// Prepares a readable root directory for the export at `url`.
    ///
    /// Zip files are unzipped to a temp directory; folders are used in place.
    /// Returns the resolved root plus a `cleanup` closure the caller must invoke
    /// when done (it removes any temporary unzip directory).
    static func prepareRootURL(from url: URL) throws -> (rootURL: URL, cleanup: () -> Void) {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            // Unzip into a unique temp directory; cleanup removes it later.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("notion-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try unzip(archiveURL: url, destinationURL: destination)
            let root = resolvedRoot(in: destination)
            return (root, { try? FileManager.default.removeItem(at: destination) })
        }

        // Non-zip: must be an existing directory.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NotionImportError.inaccessibleExport
        }
        return (resolvedRoot(in: url), {})
    }

    /// Descends into a lone wrapper subdirectory when the export was nested one
    /// level deep (a common Notion zip layout), otherwise returns `url` as-is.
    private static func resolvedRoot(in url: URL) -> URL {
        if let child = singleSubdirectory(in: url) {
            // Prefer the child only when the top level has no entries but the
            // child does.
            let parentEntries = (try? NotionExportParser.scanExport(at: url)) ?? []
            let childEntries = (try? NotionExportParser.scanExport(at: child)) ?? []
            if parentEntries.isEmpty && !childEntries.isEmpty {
                return child
            }
        }
        return url
    }

    /// Returns the single subdirectory of `url` when it contains exactly one
    /// (and it's a directory), else nil.
    private static func singleSubdirectory(in url: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), children.count == 1,
        let values = try? children[0].resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true else {
            return nil
        }
        return children[0]
    }

    /// Unzips `archiveURL` into `destinationURL` using the system `unzip`
    /// (macOS only; throws on other platforms or non-zero exit).
    private static func unzip(archiveURL: URL, destinationURL: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archiveURL.path, "-d", destinationURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw NotionImportError.unzipFailed(message)
        }
        #else
        throw NotionImportError.unzipFailed("Unzipping Notion exports is supported on macOS only. Unzip the export first.")
        #endif
    }
}
