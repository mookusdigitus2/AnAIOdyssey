// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
// Portions adapted from Odysseus v1.0, Copyright (c) 2025 Odysseus Contributors,
// used under the MIT License (see ACKNOWLEDGMENTS.md).
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// Agent tool: reads a document's content into the conversation.
///
/// Input is an optional document id (or prefix); when omitted it falls back to
/// the active document, then to the most recent one. Reading also sets the active
/// document so a subsequent `edit_document` targets the same file. Output is
/// truncated to keep the model's context manageable.
@MainActor
struct ReadDocumentTool: AgentTool {
    let name = "read_document"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Target = explicit id from the block, else the active document.
        let targetID = content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.activeDocumentID

        // Resolve by prefix among library docs, then by exact id, else default to the newest.
        let documents = try repositories.documents.listLibraryDocuments()
        let document: Document?
        if let targetID {
            if let resolved = AgentToolSupport.resolveByID(targetID, in: documents, id: \.id) {
                document = resolved
            } else {
                document = try repositories.documents.fetchDocument(id: targetID)
            }
        } else {
            document = documents.first
        }

        guard let document else {
            return "No document found to read."
        }

        // Remember this as the active document for follow-up edits.
        context.activeDocumentID = document.id
        let body = document.currentContent
        let (preview, truncated) = AgentToolSupport.truncate(body)
        var result = """
        Document: \(document.title) (id: \(document.id))
        Language: \(document.language ?? "text")
        Size: \(body.count) chars

        ```
        \(preview)
        ```
        """
        if truncated {
            result += "\n(Content truncated for display.)"
        }
        return result
    }
}

/// Agent tool: applies targeted find/replace edits to the active document.
///
/// Input is one or more `<<<FIND>>>/<<<REPLACE>>>/<<<END>>>` blocks (parsed by
/// `AgentToolParser`). Edits apply to the active document (or the most recent one)
/// and are saved as a new AI-sourced version. Counts how many edits applied vs.
/// skipped so the model can react to partial matches.
@MainActor
struct EditDocumentTool: AgentTool {
    let name = "edit_document"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Parse the FIND/REPLACE blocks; bail early if none are well-formed.
        let edits = AgentToolParser.parseEditBlocks(from: content)
        guard !edits.isEmpty else {
            return "No valid <<<FIND>>>...<<<REPLACE>>>...<<<END>>> blocks found."
        }

        // Edit the active document, or fall back to the most recent one.
        let document: Document?
        if let activeID = context.activeDocumentID {
            document = try repositories.documents.fetchDocument(id: activeID)
        } else {
            document = try repositories.documents.listLibraryDocuments().first
        }

        guard let document else {
            return "No documents exist to edit."
        }

        context.activeDocumentID = document.id
        var updatedContent = document.currentContent
        var applied = 0
        var skipped = 0

        for edit in edits {
            // Direct match: replace the first occurrence of the find text.
            if updatedContent.contains(edit.find) {
                if let range = updatedContent.range(of: edit.find) {
                    updatedContent.replaceSubrange(range, with: edit.replace)
                    applied += 1
                }
            } else {
                // Recovery: models sometimes prefix lines with "<number>\t" (line numbers); strip those and retry.
                let stripped = edit.find
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> String in
                        if let tabIndex = line.firstIndex(of: "\t"),
                           line[..<tabIndex].allSatisfy(\.isNumber) {
                            return String(line[line.index(after: tabIndex)...])
                        }
                        return String(line)
                    }
                    .joined(separator: "\n")

                if stripped != edit.find, updatedContent.contains(stripped),
                   let range = updatedContent.range(of: stripped) {
                    updatedContent.replaceSubrange(range, with: edit.replace)
                    applied += 1
                } else {
                    // Couldn't match this edit even after stripping; count it as skipped.
                    skipped += 1
                }
            }
        }

        guard applied > 0 else {
            return "No edits applied — none of the FIND blocks matched (skipped \(skipped))."
        }

        // Persist the result as a new AI-attributed document version.
        _ = document.saveContent(updatedContent, summary: "Edited by agent (\(applied) edit(s))", source: "ai")
        try repositories.documents.save()
        context.taskProgress?.recordChange(
            action: "edited",
            kind: "document",
            itemID: document.id,
            title: document.title
        )
        return "Document edited: \(document.title) v\(document.versionCount), \(applied) edit(s) applied, \(skipped) skipped."
    }
}

/// Hands a writing brief to the Documents feature (feature model + generation + saved Document).
@MainActor
struct WriteDocumentTool: AgentTool {
    let name = "write_document"

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let parsed = AgentTaskRunPolicy.parseDocumentWriteInput(content)
        guard !parsed.brief.isEmpty || parsed.title != nil else {
            return "Provide a title or brief for the document."
        }
        guard let writer = context.documentWriter else {
            return "Documents writing is not configured for this task run."
        }
        let displayTitle = parsed.title ?? parsed.brief
        context.taskProgress?.setCurrentAction(
            AgentTaskRunPolicy.currentAction(action: "created", title: displayTitle)
        )
        let shouldContinue = context.shouldContinueTool ?? { true }
        do {
            var extraContext = parsed.context
            if extraContext == nil, let researchID = context.activeResearchID,
               let report = try? context.repositories.researchReports.fetchReport(id: researchID) {
                extraContext = "Research: \(report.query)\n\n\(report.summary)"
            }
            let result = try await writer.writeDocument(
                title: parsed.title,
                brief: parsed.brief,
                existingDocumentID: parsed.documentID,
                extraContext: extraContext,
                shouldContinue: shouldContinue
            )
            context.activeDocumentID = result.id
            context.taskProgress?.recordChange(
                action: result.created ? "created" : "edited",
                kind: "document",
                itemID: result.id,
                title: result.title
            )
            let verb = result.created ? "Created" : "Edited"
            return """
            \(verb) document '\(result.title)' (id: \(result.id)).
            Saved as a Document by the Documents writing feature.

            Excerpt:
            \(result.excerpt)
            """
        } catch is CancellationError {
            return "Document writing was interrupted (paused or stopped) and was not saved. After Continue, call write_document again with the same brief."
        }
    }
}

/// Agent tool: creates a new document from the model's text.
///
/// Input uses the title-on-line-1, body-after convention. The new document is
/// attributed to the AI and becomes the active document for follow-up edits.
@MainActor
struct CreateDocumentTool: AgentTool {
    let name = "create_document"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        // Peel an optional trailing `folder:` metadata line, then title/body.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let metadata = AgentToolSupport.parseMetadataLines(from: &lines)
        let parsed = AgentToolSupport.parseTitleBody(from: lines.joined(separator: "\n"))

        let folder = try AgentFolderSupport.resolveFolderID(metadata["folder"], kind: .documents, repositories: repositories)
        guard folder.found else {
            return "Target folder '\(metadata["folder"] ?? "")' not found in documents."
        }

        let document = try repositories.documents.createDocument(
            title: parsed.title,
            content: parsed.body,
            parentID: folder.id
        )
        document.sessionID = context.sessionID
        // Record an initial AI-sourced version, then persist.
        _ = document.saveContent(parsed.body, summary: "Created by agent", source: "ai")
        try repositories.documents.save()

        context.activeDocumentID = document.id
        context.taskProgress?.recordChange(
            action: "created",
            kind: "document",
            itemID: document.id,
            title: parsed.title
        )
        let path = AgentFolderSupport.path(forFolderID: folder.id, kind: .documents, repositories: repositories)
        return "Created document '\(parsed.title)' (id: \(document.id), version 1) at \(path)."
    }
}

/// Replaces a document's body (and optional title) through the same save path as the editor.
@MainActor
struct UpdateDocumentTool: AgentTool {
    let name = "update_document"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetID = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.activeDocumentID
        if lines.first != nil { lines.removeFirst() }

        var newTitle: String?
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           first.lowercased().hasPrefix("title:") {
            newTitle = String(first.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces).nilIfEmpty
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")

        guard let document = try resolveDocument(id: targetID, repositories: repositories) else {
            return "No document found to update."
        }
        if let newTitle {
            try repositories.documents.updateDocument(id: document.id, title: newTitle, content: nil)
        }
        if !body.isEmpty {
            _ = document.saveContent(body, summary: "Updated by agent", source: "ai")
        }
        try repositories.documents.save()
        context.activeDocumentID = document.id
        let title = newTitle ?? document.title
        context.taskProgress?.recordChange(
            action: "edited",
            kind: "document",
            itemID: document.id,
            title: title
        )
        return "Updated document \(title) (id: \(document.id))."
    }
}

/// Appends text to a document without wiping existing content.
@MainActor
struct AppendDocumentTool: AgentTool {
    let name = "append_document"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetID = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.activeDocumentID
        if lines.first != nil { lines.removeFirst() }
        let addition = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else {
            return "Provide text to append after the document id."
        }
        guard let document = try resolveDocument(id: targetID, repositories: repositories) else {
            return "No document found to append to."
        }
        let updated = document.currentContent.isEmpty
            ? addition
            : document.currentContent + "\n\n" + addition
        _ = document.saveContent(updated, summary: "Appended by agent", source: "ai")
        try repositories.documents.save()
        context.activeDocumentID = document.id
        context.taskProgress?.recordChange(
            action: "edited",
            kind: "document",
            itemID: document.id,
            title: document.title
        )
        return "Updated document \(document.title) (id: \(document.id))."
    }
}

@MainActor
private func resolveDocument(id: String?, repositories: RepositoryBundle) throws -> Document? {
    let documents = try repositories.documents.listLibraryDocuments()
    if let id {
        if let match = AgentToolSupport.resolveByID(id, in: documents, id: \.id) {
            return match
        }
        return try repositories.documents.fetchDocument(id: id)
    }
    return documents.first
}

/// Agent tool: lists library documents with one-line previews.
///
/// Takes no input; output is capped at `listLimit` with a "+N more" note.
@MainActor
struct ListDocumentsTool: AgentTool {
    let name = "list_documents"
    private let repositories: RepositoryBundle

    init(repositories: RepositoryBundle) {
        self.repositories = repositories
    }

    func execute(content: String, context: inout AgentContext) async throws -> String {
        let documents = try repositories.documents.listLibraryDocuments()
        guard !documents.isEmpty else {
            return "No documents in the library."
        }

        let lines = documents.prefix(AgentToolSupport.listLimit).map { doc in
            let snippet = doc.currentContent
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            let path = AgentFolderSupport.path(forFolderID: doc.parentID, kind: .documents, repositories: repositories)
            return "- \(doc.title) (id: \(doc.id), folder: \(path), updated: \(AgentToolSupport.formatDate(doc.updatedAt))) — \(snippet)"
        }
        var result = "Documents (\(documents.count)):\n" + lines.joined(separator: "\n")
        if documents.count > AgentToolSupport.listLimit {
            result += "\n... and \(documents.count - AgentToolSupport.listLimit) more."
        }
        return result
    }
}
