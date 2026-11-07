// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// The Documents workspace: a folder-tree sidebar over an editor, built on the
/// shared ``FolderWorkspaceView`` scaffold.
///
/// Documents live in a real, nestable folder hierarchy (`Folder`, kind
/// `.documents`). Selecting a document opens it in the editor; edits autosave
/// with a short debounce.
struct DocumentsWorkspaceView: View {
    /// Document persistence (the scaffold handles folders itself).
    @Environment(\.repositories) private var repositories
    /// Coalesces rapid title/content edits into one save (see `Debouncer`).
    @State private var saveDebouncer = Debouncer()

    var body: some View {
        FolderWorkspaceView(
            title: "Documents",
            folderKind: .documents,
            itemIcon: "doc.text",
            newItemLabel: "New Document",
            newItemAccessibilityID: "new-document-button",
            deleteAlertTitle: "Delete Document?",
            itemTitle: { (document: DocumentModel) in document.title },
            itemParentID: { $0.parentID },
            deleteAlertMessage: { document in
                "“\(document.title)” and its version history will be permanently deleted."
            },
            listItems: { () -> [DocumentModel] in
                guard let repositories else { return [] }
                return (try? repositories.documents.listLibraryDocuments()) ?? []
            },
            makeItem: { (parent: String?) -> DocumentModel? in
                guard let repositories else { return nil }
                return try? repositories.documents.createDocument(title: "Untitled", content: "", parentID: parent)
            },
            moveItem: { id, folderID in
                guard let repositories else { return }
                try? repositories.documents.moveDocument(id: id, toFolderID: folderID)
            },
            removeItem: { document in
                guard let repositories else { return }
                try? repositories.documents.deleteDocument(id: document.id)
            },
            extraToolbar: {}
        ) { context in
            if let document = context.selectedItem {
                DocumentEditorView(
                    document: document,
                    onTitleChange: { title in
                        scheduleSave(documentID: document.id, title: title, content: nil, reload: context.reload)
                    },
                    onContentChange: { content in
                        scheduleSave(documentID: document.id, title: nil, content: content, reload: context.reload)
                    },
                    onDelete: { context.requestDelete(document) }
                )
                .id(document.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Document Selected",
                    systemImage: "doc.text",
                    description: Text("Select a document, or create one with the + button.")
                )
                .accessibilityIdentifier("documents-empty-state")
            }
        }
    }

    /// Debounced autosave: coalesces rapid title/content edits into one write
    /// after the last change. Passing `nil` for a field leaves it unchanged.
    private func scheduleSave(documentID: String, title: String?, content: String?, reload: @escaping () -> Void) {
        saveDebouncer.schedule {
            guard let repositories else { return }
            try? repositories.documents.updateDocument(id: documentID, title: title, content: content)
            reload()
        }
    }
}

/// Editor for a single document: an inline title field with a delete button over a
/// monospaced content editor. Edits are reported upward via callbacks so the
/// parent can debounce and persist them.
struct DocumentEditorView: View {
    /// The live document model; mutations are observed via `@Bindable`.
    @Bindable var document: Document
    /// Reports title edits to the parent for debounced saving.
    let onTitleChange: (String) -> Void
    /// Reports content edits to the parent for debounced saving.
    let onContentChange: (String) -> Void
    /// Requests deletion of this document (parent confirms).
    let onDelete: () -> Void

    /// Whether the body shows the rendered markdown preview instead of the
    /// editor. Persisted so the chosen mode sticks across documents/launches.
    @AppStorage("anaiodyssey.documents.markdownPreview") private var markdownPreview = false

    /// Title row over the monospaced body editor (or its markdown preview).
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: Binding(
                    get: { document.title },
                    set: { newValue in
                        document.title = newValue
                        onTitleChange(newValue)
                    }
                ))
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .accessibilityIdentifier("document-title-field")

                Spacer()

                // Edit ↔ rendered-markdown preview switch.
                Picker("Mode", selection: $markdownPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("document-preview-mode-picker")

                WorkspaceTextShareLink(
                    title: document.title.isEmpty ? "Untitled" : document.title,
                    text: WorkspaceShareContent.documentPlainText(
                        title: document.title,
                        content: document.currentContent
                    ),
                    accessibilityIdentifier: "share-document-button"
                )

                Button("Delete", role: .destructive, action: onDelete)
                    .workspaceActionButtonTint(destructive: true)
                    .accessibilityIdentifier("delete-document-detail-button")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if markdownPreview {
                // Read-only rendered markdown of the document body.
                ScrollView {
                    MarkdownContentView(content: document.currentContent)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("document-markdown-preview")
            } else {
                // Monospaced body editor; writes flow back through the change callback.
                WorkspaceTextEditor(
                    text: Binding(
                        get: { document.currentContent },
                        set: { newValue in
                            document.currentContent = newValue
                            onContentChange(newValue)
                        }
                    ),
                    font: .body.monospaced(),
                    accessibilityIdentifier: "document-editor"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .workspaceFillDetailPane()
    }
}
