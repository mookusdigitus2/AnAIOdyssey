// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

// Agent tools exposing the folder tree (Documents & Notes) and task nesting so
// the model can navigate, organize, and create knowledge anywhere in the app.
// These follow the same conventions as the other agent tools: `AgentTool`
// conformance, fenced-block text input, plain-text output, registered in
// `AgentStandardTools.all` and described in `AgentToolRegistry.toolDescriptions`.

/// Shared helpers for resolving folders by id or `/path` and rendering trees.
@MainActor
enum AgentFolderSupport {
    /// Parses the leading `kind:` of a block (or a bare `documents`/`notes`
    /// token), defaulting to `.documents`. Returns the kind and the remaining
    /// lines with that token removed.
    static func parseKind(from content: String, default fallback: FolderKind = .documents) -> FolderKind {
        let lowered = content.lowercased()
        if lowered.contains("notes") { return .notes }
        if lowered.contains("documents") { return .documents }
        return fallback
    }

    /// Resolves a folder reference to a folder id (`nil` = root).
    ///
    /// Accepts an empty string / `/` (root), an exact-or-prefix folder id, or a
    /// `/A/B` path matched case-insensitively within `kind`. Returns
    /// `(found: false, nil)` when a non-empty reference can't be resolved.
    static func resolveFolderID(
        _ reference: String?,
        kind: FolderKind,
        repositories: RepositoryBundle
    ) throws -> (found: Bool, id: String?) {
        let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ref.isEmpty || ref == "/" {
            return (true, nil)
        }

        let allFolders = try repositories.folders.listAllFolders(kind: kind)

        // Path form: "/A/B" or "A/B".
        if ref.contains("/") {
            let components = ref.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var parentID: String?
            for component in components {
                guard let match = allFolders.first(where: {
                    $0.parentID == parentID && $0.name.localizedCaseInsensitiveCompare(component) == .orderedSame
                }) else {
                    return (false, nil)
                }
                parentID = match.id
            }
            return (true, parentID)
        }

        // Id (exact or unique prefix).
        if let resolved = AgentToolSupport.resolveByID(ref, in: allFolders, id: \.id) {
            return (true, resolved.id)
        }
        // Single-name match anywhere in the tree as a last resort.
        let byName = allFolders.filter { $0.name.localizedCaseInsensitiveCompare(ref) == .orderedSame }
        if byName.count == 1 {
            return (true, byName[0].id)
        }
        return (false, nil)
    }

    /// Builds the `/A/B` path string for a folder id within `kind`.
    static func path(
        forFolderID folderID: String?,
        kind: FolderKind,
        repositories: RepositoryBundle,
        cache: inout [String: String]?
    ) -> String {
        let key = folderID ?? "__root__"
        if let map = cache, let cached = map[key] {
            return cached
        }
        let computed = pathUncached(forFolderID: folderID, kind: kind, repositories: repositories)
        if cache != nil {
            cache?[key] = computed
        }
        return computed
    }

    static func path(forFolderID folderID: String?, kind: FolderKind, repositories: RepositoryBundle) -> String {
        var nilCache: [String: String]? = nil
        return path(forFolderID: folderID, kind: kind, repositories: repositories, cache: &nilCache)
    }

    private static func pathUncached(forFolderID folderID: String?, kind: FolderKind, repositories: RepositoryBundle) -> String {
        guard let folderID else { return "/" }
        let all = (try? repositories.folders.listAllFolders(kind: kind)) ?? []
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        var currentID: String? = folderID
        var guardCount = 0
        while let id = currentID, let folder = byID[id], guardCount < 1000 {
            names.append(folder.name)
            currentID = folder.parentID
            guardCount += 1
        }
        return "/" + names.reversed().joined(separator: "/")
    }

    /// Renders the full folder tree of `kind` as an indented list with ids.
    static func renderTree(kind: FolderKind, repositories: RepositoryBundle) throws -> String {
        let all = try repositories.folders.listAllFolders(kind: kind)
        guard !all.isEmpty else { return "(no folders)" }
        let childrenByParent = Dictionary(grouping: all, by: { $0.parentID })

        var lines: [String] = []
        func walk(parentID: String?, depth: Int) {
            let children = (childrenByParent[parentID] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for folder in children {
                let indent = String(repeating: "  ", count: depth)
                lines.append("\(indent)- \(folder.name)/ (id: \(folder.id))")
                walk(parentID: folder.id, depth: depth + 1)
            }
        }
        walk(parentID: nil, depth: 0)
        return lines.joined(separator: "\n")
    }
}

/// Agent tool: lists the Documents and/or Notes folder tree with ids.
@MainActor
struct ListFoldersTool: AgentTool {
    let name = "list_folders"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // No filter → show both trees; otherwise just the requested kind.
        let kinds: [FolderKind]
        if trimmed == "notes" {
            kinds = [.notes]
        } else if trimmed == "documents" {
            kinds = [.documents]
        } else {
            kinds = [.documents, .notes]
        }

        var sections: [String] = []
        for kind in kinds {
            let tree = try AgentFolderSupport.renderTree(kind: kind, repositories: repositories)
            sections.append("\(kind.rawValue.capitalized) folders:\n\(tree)")
        }
        return sections.joined(separator: "\n\n")
    }
}

/// Agent tool: lists the contents (subfolders + items) of one folder by id or path.
@MainActor
struct BrowseFolderTool: AgentTool {
    let name = "browse_folder"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Optional `kind:` line; remaining content is the folder id/path (empty = root).
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        let kind = FolderKind(rawValue: (metadata["kind"] ?? "").lowercased()) ?? .documents
        let reference = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let resolved = try AgentFolderSupport.resolveFolderID(reference, kind: kind, repositories: repositories)
        guard resolved.found else {
            return "No \(kind.rawValue) folder found matching '\(reference)'."
        }
        let folderID = resolved.id
        let path = AgentFolderSupport.path(forFolderID: folderID, kind: kind, repositories: repositories)

        var out = "Contents of \(path) [\(kind.rawValue)]:"

        let subfolders = try repositories.folders.listFolders(kind: kind, parent: folderID)
        for folder in subfolders {
            out += "\n- \(folder.name)/ (folder, id: \(folder.id))"
        }

        switch kind {
        case .documents:
            let docs = try repositories.documents.listDocuments(inFolder: folderID)
            for doc in docs.prefix(AgentToolSupport.listLimit) {
                out += "\n- \(doc.title) (document, id: \(doc.id))"
            }
        case .notes:
            let notes = try repositories.notes.listNotes(inFolder: folderID, includeArchived: false)
            for note in notes.prefix(AgentToolSupport.listLimit) {
                out += "\n- \(note.title) (note, id: \(note.id))"
            }
        }

        if subfolders.isEmpty {
            switch kind {
            case .documents where (try? repositories.documents.listDocuments(inFolder: folderID))?.isEmpty ?? true:
                out += "\n(empty)"
            case .notes where (try? repositories.notes.listNotes(inFolder: folderID, includeArchived: false))?.isEmpty ?? true:
                out += "\n(empty)"
            default:
                break
            }
        }
        return out
    }
}

/// Agent tool: creates a folder in the Documents or Notes tree.
///
/// Input: line 1 = folder name; optional trailing `kind:` and `parent:` metadata.
@MainActor
struct CreateFolderTool: AgentTool {
    let name = "create_folder"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        let name = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled Folder"
        let kind = FolderKind(rawValue: (metadata["kind"] ?? "").lowercased()) ?? .documents

        let parent = try AgentFolderSupport.resolveFolderID(metadata["parent"], kind: kind, repositories: repositories)
        guard parent.found else {
            return "Parent folder '\(metadata["parent"] ?? "")' not found in \(kind.rawValue)."
        }

        let folder = try repositories.folders.createFolder(name: name, kind: kind, parentID: parent.id)
        let path = AgentFolderSupport.path(forFolderID: folder.id, kind: kind, repositories: repositories)
        return "Created folder '\(name)' (id: \(folder.id)) at \(path) [\(kind.rawValue)]."
    }
}

/// Agent tool: moves a document, note, or folder into a target folder.
///
/// Input: line 1 = `document <id>` | `note <id>` | `folder <id>`; line 2 (or a
/// `to:` metadata line) = destination folder id/path (empty/`/` = root).
@MainActor
struct MoveItemTool: AgentTool {
    let name = "move_item"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return "First line must be '<document|note|folder> <id>'."
        }
        lines.removeFirst()

        let parts = first.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "First line must be '<document|note|folder> <id>'."
        }
        let type = parts[0].lowercased()
        let id = parts[1].trimmingCharacters(in: .whitespaces)
        let destinationRef = metadata["to"] ?? lines.joined(separator: "\n")

        switch type {
        case "document":
            let dest = try AgentFolderSupport.resolveFolderID(destinationRef, kind: .documents, repositories: repositories)
            guard dest.found else { return "Destination folder not found in documents." }
            try repositories.documents.moveDocument(id: id, toFolderID: dest.id)
            try repositories.documents.save()
            return "Moved document \(id) to \(AgentFolderSupport.path(forFolderID: dest.id, kind: .documents, repositories: repositories))."
        case "note":
            let dest = try AgentFolderSupport.resolveFolderID(destinationRef, kind: .notes, repositories: repositories)
            guard dest.found else { return "Destination folder not found in notes." }
            try repositories.notes.moveNote(id: id, toFolderID: dest.id)
            try repositories.notes.save()
            return "Moved note \(id) to \(AgentFolderSupport.path(forFolderID: dest.id, kind: .notes, repositories: repositories))."
        case "folder":
            // A folder may be in either tree; look it up to learn its kind.
            guard let folder = try repositories.folders.fetchFolder(id: id) else {
                return "No folder found with id '\(id)'."
            }
            let dest = try AgentFolderSupport.resolveFolderID(destinationRef, kind: folder.folderKind, repositories: repositories)
            guard dest.found else { return "Destination folder not found." }
            try repositories.folders.moveFolder(id: id, newParentID: dest.id)
            return "Moved folder \(id) to \(AgentFolderSupport.path(forFolderID: dest.id, kind: folder.folderKind, repositories: repositories))."
        default:
            return "Unknown item type '\(type)'. Use document, note, or folder."
        }
    }
}

/// Agent tool: lists the direct subtasks of a task (or top-level tasks when empty).
@MainActor
struct ListSubtasksTool: AgentTool {
    let name = "list_subtasks"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let parentID = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let subtasks = try repositories.tasks.listSubtasks(parentTaskID: parentID, status: nil)
        guard !subtasks.isEmpty else {
            return parentID.map { "Task \($0) has no subtasks." } ?? "No top-level tasks."
        }
        let lines = subtasks.prefix(AgentToolSupport.listLimit).map { task in
            "- \(task.name) (id: \(task.id), status: \(task.status))"
        }
        let header = parentID.map { "Subtasks of \($0)" } ?? "Top-level tasks"
        return "\(header) (\(subtasks.count)):\n" + lines.joined(separator: "\n")
    }
}
