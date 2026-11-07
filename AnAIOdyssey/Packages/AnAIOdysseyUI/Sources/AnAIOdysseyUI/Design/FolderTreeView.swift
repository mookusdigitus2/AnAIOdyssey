// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI

/// A reusable folder/file tree sidebar for the Documents and Notes workspaces.
///
/// Renders a nestable hierarchy (folders containing subfolders and items) with an
/// `OutlineGroup`, backed by flat `folders`/`items` arrays keyed by `parentID`.
/// Selection is a single node id (folder or item); the host decides what to show
/// in the detail pane and which folder is the "current" create target. All
/// mutations are surfaced as intents so the host owns persistence and alerts.
struct FolderTreeView: View {
    /// One folder in the tree.
    struct FolderInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let parentID: String?
    }

    /// One leaf item (document or note) in the tree.
    struct ItemInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let parentID: String?
    }

    let folders: [FolderInfo]
    let items: [ItemInfo]
    /// SF Symbol used for leaf items (e.g. `doc.text`, `note.text`).
    let itemIcon: String
    /// Selected node id (a folder id or an item id), shared with the host.
    @Binding var selection: String?

    // Intents handled by the host.
    var onNewSubfolder: (_ parentFolderID: String?) -> Void
    var onNewItem: (_ parentFolderID: String?) -> Void
    var onRenameFolder: (_ id: String) -> Void
    var onDeleteFolder: (_ id: String) -> Void
    var onDeleteItem: (_ id: String) -> Void
    var onMoveItem: (_ id: String, _ toFolderID: String?) -> Void
    var onMoveFolder: (_ id: String, _ toFolderID: String?) -> Void

    /// A built tree node combining folders and items for `OutlineGroup`.
    private struct Node: Identifiable {
        let id: String
        let name: String
        let isFolder: Bool
        var children: [Node]?
    }

    /// Whether the given selected/queried node id refers to a folder.
    static func isFolder(_ id: String?, folders: [FolderInfo]) -> Bool {
        guard let id else { return false }
        return folders.contains { $0.id == id }
    }

    var body: some View {
        List(selection: $selection) {
            OutlineGroup(rootNodes, children: \.children) { node in
                row(for: node)
            }
        }
    }

    /// Builds the top-level forest from the flat folder/item arrays.
    private var rootNodes: [Node] {
        nodes(parentID: nil)
    }

    /// Recursively assembles nodes under `parentID` (folders first, then items),
    /// each sorted by name/title.
    private func nodes(parentID: String?) -> [Node] {
        let folderNodes = folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { folder in
                Node(id: folder.id, name: folder.name, isFolder: true, children: nodes(parentID: folder.id))
            }
        let itemNodes = items
            .filter { $0.parentID == parentID }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { item in
                Node(id: item.id, name: item.title.isEmpty ? "Untitled" : item.title, isFolder: false, children: nil)
            }
        return folderNodes + itemNodes
    }

    /// A single tree row with its context menu.
    @ViewBuilder
    private func row(for node: Node) -> some View {
        if node.isFolder {
            Label(node.name, systemImage: "folder")
                .tag(node.id)
                .accessibilityIdentifier("tree-folder-\(node.id)")
                .contextMenu { folderMenu(node.id) }
        } else {
            Label(node.name, systemImage: itemIcon)
                .tag(node.id)
                .accessibilityIdentifier("tree-item-\(node.id)")
                .contextMenu { itemMenu(node.id) }
        }
    }

    /// Context menu for a folder: create inside it, rename, move, delete.
    @ViewBuilder
    private func folderMenu(_ folderID: String) -> some View {
        Button("New Subfolder") { onNewSubfolder(folderID) }
        Button("New Item Here") { onNewItem(folderID) }
        Divider()
        Button("Rename…") { onRenameFolder(folderID) }
        moveMenu(excluding: folderID) { destination in onMoveFolder(folderID, destination) }
        Divider()
        Button("Delete Folder", role: .destructive) { onDeleteFolder(folderID) }
    }

    /// Context menu for an item: move or delete.
    @ViewBuilder
    private func itemMenu(_ itemID: String) -> some View {
        moveMenu(excluding: nil) { destination in onMoveItem(itemID, destination) }
        Divider()
        Button("Delete", role: .destructive) { onDeleteItem(itemID) }
    }

    /// A "Move to" submenu listing Root and every folder by path. When moving a
    /// folder, `excluding` drops that folder (and its descendants) to avoid cycles.
    @ViewBuilder
    private func moveMenu(excluding excludedFolderID: String?, action: @escaping (String?) -> Void) -> some View {
        Menu("Move to") {
            Button("Root") { action(nil) }
            ForEach(movableFolders(excluding: excludedFolderID), id: \.id) { folder in
                Button(path(for: folder.id)) { action(folder.id) }
            }
        }
    }

    /// Folders eligible as a move destination (excludes a folder and its subtree).
    private func movableFolders(excluding excludedFolderID: String?) -> [FolderInfo] {
        guard let excludedFolderID else {
            return folders.sorted { path(for: $0.id) < path(for: $1.id) }
        }
        let blocked = descendantIDs(of: excludedFolderID).union([excludedFolderID])
        return folders
            .filter { !blocked.contains($0.id) }
            .sorted { path(for: $0.id) < path(for: $1.id) }
    }

    /// All descendant folder ids of `folderID`.
    private func descendantIDs(of folderID: String) -> Set<String> {
        var result: Set<String> = []
        var stack = [folderID]
        while let current = stack.popLast() {
            for child in folders where child.parentID == current {
                if result.insert(child.id).inserted {
                    stack.append(child.id)
                }
            }
        }
        return result
    }

    /// Builds the `/A/B` path label for a folder id.
    private func path(for folderID: String) -> String {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        var current: String? = folderID
        var guardCount = 0
        while let id = current, let folder = byID[id], guardCount < 1000 {
            names.append(folder.name)
            current = folder.parentID
            guardCount += 1
        }
        return "/" + names.reversed().joined(separator: "/")
    }
}
