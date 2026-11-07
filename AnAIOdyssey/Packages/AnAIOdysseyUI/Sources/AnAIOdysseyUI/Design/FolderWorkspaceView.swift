// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// What ``FolderWorkspaceView`` hands its host's detail builder.
struct FolderWorkspaceContext<Item> {
    /// The selected item, when the selection is an item rather than a folder.
    let selectedItem: Item?
    /// Runs the scaffold's delete-confirmation flow for `item`.
    let requestDelete: (Item) -> Void
    /// Reloads folders + items (call after edits that change tree titles).
    let reload: () -> Void
}

/// Shared scaffold for the folder-tree workspaces (Documents, Notes): a
/// ``FolderTreeView`` sidebar over a host-supplied detail pane.
///
/// The scaffold owns everything the two workspaces used to duplicate
/// line-for-line — tree selection, folder create/rename/move/delete (with the
/// rename alert and delete confirmations), item delete confirmation, and the
/// "New" toolbar menu. The host supplies the domain specifics: how to list,
/// create, move, and delete items, how to title them, and the detail editor.
struct FolderWorkspaceView<Item: Identifiable, ExtraToolbar: View, Detail: View>: View where Item.ID == String {
    @Environment(\.repositories) private var repositories
    #if os(iOS)
    /// iPhone portrait is compact; a nested split view can't show its detail
    /// column there, so we fall back to push navigation.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Navigation title for the sidebar column.
    let title: String
    /// Which folder tree this workspace edits (`.documents` or `.notes`).
    let folderKind: FolderKind
    /// SF Symbol for leaf items in the tree.
    let itemIcon: String
    /// Label + accessibility id for the "new item" menu entry.
    let newItemLabel: String
    let newItemAccessibilityID: String
    /// Title and message for the item delete confirmation.
    let deleteAlertTitle: String
    let deleteAlertMessage: (Item) -> String
    /// Changing this value triggers a reload (e.g. an "archived" filter toggle).
    let reloadToken: AnyHashable?
    /// Item projections for the tree.
    let itemTitle: (Item) -> String
    let itemParentID: (Item) -> String?
    /// Item persistence, supplied by the host's repository.
    let listItems: () -> [Item]
    let makeItem: (_ parentFolderID: String?) -> Item?
    let moveItem: (_ id: String, _ toFolderID: String?) -> Void
    let removeItem: (Item) -> Void
    /// Extra toolbar content beside the "New" menu (pass `{}` for none).
    let extraToolbar: ExtraToolbar
    /// Detail pane builder (selected item's editor, or an empty state).
    let detail: (FolderWorkspaceContext<Item>) -> Detail

    /// All folders in this workspace's tree.
    @State private var folders: [Folder] = []
    /// Locally cached item list backing the tree.
    @State private var items: [Item] = []
    /// Currently selected tree node (a folder id or an item id).
    @State private var selection: String?
    /// Item awaiting delete confirmation.
    @State private var itemPendingDeletion: Item?
    /// Folder id awaiting delete confirmation.
    @State private var folderPendingDeletion: String?
    /// Folder id being renamed and the in-progress name text.
    @State private var renamingFolderID: String?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    init(
        title: String,
        folderKind: FolderKind,
        itemIcon: String,
        newItemLabel: String,
        newItemAccessibilityID: String,
        deleteAlertTitle: String,
        reloadToken: AnyHashable? = nil,
        itemTitle: @escaping (Item) -> String,
        itemParentID: @escaping (Item) -> String?,
        deleteAlertMessage: @escaping (Item) -> String,
        listItems: @escaping () -> [Item],
        makeItem: @escaping (_ parentFolderID: String?) -> Item?,
        moveItem: @escaping (_ id: String, _ toFolderID: String?) -> Void,
        removeItem: @escaping (Item) -> Void,
        @ViewBuilder extraToolbar: () -> ExtraToolbar,
        @ViewBuilder detail: @escaping (FolderWorkspaceContext<Item>) -> Detail
    ) {
        self.title = title
        self.folderKind = folderKind
        self.itemIcon = itemIcon
        self.newItemLabel = newItemLabel
        self.newItemAccessibilityID = newItemAccessibilityID
        self.deleteAlertTitle = deleteAlertTitle
        self.reloadToken = reloadToken
        self.itemTitle = itemTitle
        self.itemParentID = itemParentID
        self.deleteAlertMessage = deleteAlertMessage
        self.listItems = listItems
        self.makeItem = makeItem
        self.moveItem = moveItem
        self.removeItem = removeItem
        self.extraToolbar = extraToolbar()
        self.detail = detail
    }

    var body: some View {
        layout
            .onAppear {
                reload()
                applyPendingDocumentOpen()
            }
            .onChange(of: reloadToken) { _, _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: WorkspaceOpenRequest.notification)) { _ in
                applyPendingDocumentOpen()
            }
            .destructiveDeleteAlert(
                deleteAlertTitle,
                item: $itemPendingDeletion,
                message: deleteAlertMessage,
                confirmAction: confirmDeleteItem
            )
            .destructiveDeleteAlert(
                "Delete Folder?",
                isPresented: Binding(
                    get: { folderPendingDeletion != nil },
                    set: { if !$0 { folderPendingDeletion = nil } }
                ),
                message: "The folder is deleted; its contents move up to the parent folder.",
                confirmAction: deleteFolderConfirmed
            )
            .alert("Rename Folder", isPresented: $showRenameAlert) {
                TextField("Folder name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename", action: commitRename)
            }
    }

    /// Split view (macOS / iPad / iPhone landscape) or push navigation (iPhone
    /// portrait), where a nested split view can't reveal its detail column.
    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            folderSidebar
        } detail: {
            detail(context)
                .workspaceFillDetailPane()
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
    }

    #if os(iOS)
    /// iPhone portrait: the folder tree is the root; selecting an item pushes its
    /// editor.
    ///
    /// No `NavigationStack` of its own: the Library tab's stack (in
    /// `PhoneRootView`) hosts the push, so there is exactly one navigation bar
    /// and one Back path.
    private var compactBody: some View {
        folderSidebar
            .navigationDestination(isPresented: itemDetailPresented) {
                detail(context)
                    .workspaceFillDetailPane()
            }
    }

    /// Drives the pushed editor: present when an item (not a folder) is selected;
    /// clearing it on pop drops the selection.
    private var itemDetailPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { if !$0 { selection = nil } }
        )
    }
    #endif

    /// The folder-tree sidebar, shared by the split and compact layouts.
    private var folderSidebar: some View {
        FolderTreeView(
            folders: folders.map { .init(id: $0.id, name: $0.name, parentID: $0.parentID) },
            items: items.map { .init(id: $0.id, title: itemTitle($0), parentID: itemParentID($0)) },
            itemIcon: itemIcon,
            selection: $selection,
            onNewSubfolder: { createFolder(parent: $0) },
            onNewItem: { createItem(parent: $0) },
            onRenameFolder: { startRename($0) },
            onDeleteFolder: { folderPendingDeletion = $0 },
            onDeleteItem: { id in
                if let item = items.first(where: { $0.id == id }) {
                    itemPendingDeletion = item
                }
            },
            onMoveItem: { id, destination in
                moveItem(id, destination)
                reload()
            },
            onMoveFolder: { id, destination in moveFolder(id, to: destination) }
        )
        .macWorkspaceSplit()
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(newItemLabel, action: { createItem(parent: targetFolderID) })
                        .accessibilityIdentifier(newItemAccessibilityID)
                    Button("New Folder", action: { createFolder(parent: targetFolderID) })
                        .accessibilityIdentifier("new-folder-button")
                } label: {
                    Label("New", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                extraToolbar
            }
        }
    }

    private var context: FolderWorkspaceContext<Item> {
        FolderWorkspaceContext(
            selectedItem: selectedItem,
            requestDelete: { itemPendingDeletion = $0 },
            reload: reload
        )
    }

    /// The selected item (nil when a folder or nothing is selected).
    private var selectedItem: Item? {
        items.first { $0.id == selection }
    }

    /// The folder to create new things in: the selected folder, the selected
    /// item's folder, or root.
    private var targetFolderID: String? {
        guard let selection else { return nil }
        if folders.contains(where: { $0.id == selection }) { return selection }
        if let item = items.first(where: { $0.id == selection }) { return itemParentID(item) }
        return nil
    }

    private func applyPendingDocumentOpen() {
        guard folderKind == .documents,
              let request = WorkspaceOpenRequest.takePending(kind: .document)
        else { return }
        reload()
        if items.contains(where: { $0.id == request.itemID }) {
            selection = request.itemID
        }
    }

    /// Reloads folders + items, keeping selection valid.
    private func reload() {
        guard let repositories else { return }
        folders = (try? repositories.folders.listAllFolders(kind: folderKind)) ?? []
        items = listItems()
        if let selection,
           !folders.contains(where: { $0.id == selection }),
           !items.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    /// Creates an item in `parent` and selects it.
    private func createItem(parent: String?) {
        guard let item = makeItem(parent) else { return }
        reload()
        selection = item.id
    }

    /// Creates a folder in `parent`, selects it, and prompts to rename it.
    private func createFolder(parent: String?) {
        guard let repositories else { return }
        guard let folder = try? repositories.folders.createFolder(name: "New Folder", kind: folderKind, parentID: parent) else { return }
        reload()
        selection = folder.id
        startRename(folder.id)
    }

    /// Moves a folder under `folderID` (nil = root); cycles are rejected.
    private func moveFolder(_ id: String, to folderID: String?) {
        guard let repositories else { return }
        try? repositories.folders.moveFolder(id: id, newParentID: folderID)
        reload()
    }

    /// Runs the host's delete and clears any dangling selection.
    private func confirmDeleteItem(_ item: Item) {
        removeItem(item)
        if selection == item.id { selection = nil }
        itemPendingDeletion = nil
        reload()
    }

    /// Deletes the pending folder (its contents move up to the parent).
    private func deleteFolderConfirmed() {
        guard let repositories, let id = folderPendingDeletion else { return }
        try? repositories.folders.deleteFolder(id: id)
        if selection == id { selection = nil }
        folderPendingDeletion = nil
        reload()
    }

    /// Opens the rename alert for a folder, seeding its current name.
    private func startRename(_ folderID: String) {
        renamingFolderID = folderID
        renameText = folders.first(where: { $0.id == folderID })?.name ?? ""
        showRenameAlert = true
    }

    /// Commits the in-progress folder rename.
    private func commitRename() {
        guard let repositories, let id = renamingFolderID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? repositories.folders.renameFolder(id: id, name: trimmed)
        }
        renamingFolderID = nil
        reload()
    }
}
