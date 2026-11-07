// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// The Notes workspace: a folder-tree sidebar over a note editor, built on the
/// shared ``FolderWorkspaceView`` scaffold.
///
/// Notes live in a real, nestable folder hierarchy (`Folder`, kind `.notes`).
/// Selecting a note opens it in ``NoteEditorView``. Notes can be plain text or
/// checklists, and edits autosave.
struct NotesView: View {
    /// Note persistence (the scaffold handles folders itself).
    @Environment(\.repositories) private var repositories
    /// Whether archived notes are included in the tree.
    @State private var showArchived = false

    var body: some View {
        FolderWorkspaceView(
            title: "Notes",
            folderKind: .notes,
            itemIcon: "note.text",
            newItemLabel: "New Note",
            newItemAccessibilityID: "new-note-button",
            deleteAlertTitle: "Delete Note?",
            reloadToken: showArchived,
            itemTitle: { (note: Note) in note.title.isEmpty ? "Untitled" : note.title },
            itemParentID: { $0.parentID },
            deleteAlertMessage: { note in
                "“\(note.title.isEmpty ? "Untitled" : note.title)” will be permanently deleted."
            },
            listItems: { () -> [Note] in
                guard let repositories else { return [] }
                return (try? repositories.notes.listVisibleNotes(includeArchived: showArchived)) ?? []
            },
            makeItem: { (parent: String?) -> Note? in
                guard let repositories else { return nil }
                return try? repositories.notes.createNote(title: "New Note", content: "", parentID: parent)
            },
            moveItem: { id, folderID in
                guard let repositories else { return }
                try? repositories.notes.moveNote(id: id, toFolderID: folderID)
            },
            removeItem: { note in
                guard let repositories else { return }
                try? repositories.notes.deleteNote(id: note.id)
            },
            extraToolbar: {
                Toggle("Archived", isOn: $showArchived)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
        ) { context in
            if let note = context.selectedItem {
                NoteEditorView(
                    note: note,
                    onUpdated: context.reload,
                    onDelete: { context.requestDelete(note) }
                )
                .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Select a note, or create one with the + button.")
                )
            }
        }
    }
}

/// Editor for a single note, supporting both plain-text and checklist modes.
///
/// Binds directly to the SwiftData ``Note`` model and debounces writes through
/// ``scheduleSave()`` so rapid typing doesn't thrash persistence. The toolbar
/// exposes pin/archive, conversion to a checklist, and delete.
struct NoteEditorView: View {
    /// Note persistence for pin/archive/update operations.
    @Environment(\.repositories) private var repositories
    /// The live note model being edited; mutations are observed via `@Bindable`.
    @Bindable var note: Note
    /// Notifies the list to refresh after metadata/content changes.
    let onUpdated: () -> Void
    /// Requests deletion of this note (handled by the parent's confirmation flow).
    let onDelete: () -> Void

    /// Coalesces rapid edits into one save (see `Debouncer`).
    @State private var saveDebouncer = Debouncer()

    /// Title field over the body editor (text or checklist), with an action toolbar.
    var body: some View {
        VStack(spacing: 0) {
            // Title field — writing through the binding triggers a debounced save.
            TextField("Title", text: Binding(
                get: { note.title },
                set: { newValue in
                    note.title = newValue
                    scheduleSave()
                }
            ))
            .font(AnAIOdysseyFont.editorTitle)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityIdentifier("note-title-field")

            Divider()

            // Body switches between checklist and free-text editors by note type.
            Group {
                if note.noteType == NoteType.checklist.rawValue {
                    ScrollView {
                        checklistEditor
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .workspaceEdgeToEdgeScrollContent()
                } else {
                    WorkspaceTextEditor(
                        text: Binding(
                            get: { note.content ?? "" },
                            set: { newValue in
                                note.content = newValue
                                scheduleSave()
                            }
                        ),
                        accessibilityIdentifier: "note-content-editor"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .workspaceFillDetailPane()
        .navigationTitle(note.title.isEmpty ? "Note" : note.title)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Toggle pinned state (affects sidebar ordering).
                Button(note.pinned ? "Unpin" : "Pin") {
                    try? repositories?.notes.setPinned(id: note.id, pinned: !note.pinned)
                    onUpdated()
                }
                // Toggle archived state (affects the archived filter).
                Button(note.archived ? "Restore" : "Archive") {
                    try? repositories?.notes.setArchived(id: note.id, archived: !note.archived)
                    onUpdated()
                }
                // Convert to a checklist, seeding a first item if empty.
                Button("Checklist") {
                    note.noteType = NoteType.checklist.rawValue
                    if note.checklistItems.isEmpty {
                        note.checklistItems = [ChecklistItem(text: "First item")]
                    }
                    scheduleSave()
                }
                Button("Delete", role: .destructive, action: onDelete)
                    .workspaceActionButtonTint(destructive: true)
                    .accessibilityIdentifier("delete-note-detail-button")
            }
        }
    }

    /// Checklist body: a toggle + editable text row per item, plus an add button.
    /// Rows are keyed by each item's stable `id` (not its array position) so
    /// future insert/remove/reorder can't misattach row state; every edit writes
    /// back into the model and schedules a debounced save.
    private var checklistEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(note.checklistItems.enumerated()), id: \.element.id) { index, _ in
                Toggle(isOn: Binding(
                    get: { note.checklistItems.indices.contains(index) ? note.checklistItems[index].done : false },
                    set: { newValue in
                        guard note.checklistItems.indices.contains(index) else { return }
                        note.checklistItems[index].done = newValue
                        scheduleSave()
                    }
                )) {
                    TextField("Item", text: Binding(
                        get: { note.checklistItems.indices.contains(index) ? note.checklistItems[index].text : "" },
                        set: { newValue in
                            guard note.checklistItems.indices.contains(index) else { return }
                            note.checklistItems[index].text = newValue
                            scheduleSave()
                        }
                    ))
                }
                .accessibilityIdentifier("checklist-item-\(index)")
            }
            Button("Add Item") {
                note.checklistItems.append(ChecklistItem(text: "New item"))
                scheduleSave()
            }
        }
        .accessibilityIdentifier("note-checklist-editor")
    }

    /// Debounced autosave: coalesces rapid edits into a single write after the
    /// last change (see `Debouncer`).
    private func scheduleSave() {
        saveDebouncer.schedule {
            guard let repositories else { return }
            try? repositories.notes.updateNote(
                id: note.id,
                title: note.title,
                content: note.content,
                checklistItems: note.checklistItems
            )
            onUpdated()
        }
    }
}
