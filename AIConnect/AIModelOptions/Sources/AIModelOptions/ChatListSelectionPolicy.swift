// SPDX-License-Identifier: MIT
import Foundation

/// Copy and selection rules for bulk-deleting chats.
///
/// iPhone/iPad use an explicit Select mode; Mac uses native List multi-select.
/// Confirmation and empty-state rules are shared.
public enum ChatListSelectionPolicy {
    public static let confirmationMessage = "This can't be undone."

    public static func isAllSelected(current: Set<String>, allIDs: [String]) -> Bool {
        !allIDs.isEmpty && current.count == allIDs.count && Set(allIDs) == current
    }

    public static func toggleSelectAll(current: Set<String>, allIDs: [String]) -> Set<String> {
        isAllSelected(current: current, allIDs: allIDs) ? [] : Set(allIDs)
    }

    public static func selectAllTitle(isAllSelected: Bool) -> String {
        isAllSelected ? "Deselect All" : "Select All"
    }

    /// iOS bottom-toolbar label: "Delete 12 Chats" / "Delete 1 Chat".
    public static func deleteButtonTitle(count: Int) -> String {
        count == 1 ? "Delete 1 Chat" : "Delete \(count) Chats"
    }

    /// Mac context-menu label: "Delete Chat" for one, "Delete 12 Chats" for many.
    public static func contextMenuTitle(count: Int) -> String {
        count == 1 ? "Delete Chat" : "Delete \(count) Chats"
    }

    public static func confirmationTitle(count: Int) -> String {
        count == 1 ? "Delete 1 chat?" : "Delete \(count) chats?"
    }

    public static func confirmationSentence(count: Int) -> String {
        "\(confirmationTitle(count: count)) \(confirmationMessage)"
    }

    public static func canDelete(_ count: Int) -> Bool {
        count > 0
    }

    /// After a delete, keep the open chat only if it was not among the deleted IDs.
    /// Returning nil means the workspace should show the empty state, not pick another chat.
    public static func openSessionAfterDelete(openID: String?, deletedIDs: Set<String>) -> String? {
        guard let openID, !deletedIDs.contains(openID) else { return nil }
        return openID
    }

    public static func remainingSelection(_ current: Set<String>, afterDeleting deletedIDs: Set<String>) -> Set<String> {
        current.subtracting(deletedIDs)
    }
}
