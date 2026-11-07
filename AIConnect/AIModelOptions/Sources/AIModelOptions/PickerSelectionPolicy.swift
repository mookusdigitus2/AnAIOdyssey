// SPDX-License-Identifier: MIT
import Foundation

/// How a model picker keeps a stored default without overwriting it.
///
/// Chat/research pickers list the 10 newest models. A saved default can fall
/// off that truncated list and still be valid. Callers prepend a recognized
/// stored key, then snap only if the key is still missing (empty or invalid).
public enum PickerSelectionPolicy: Sendable {
    /// Visible row keys, with a recognized stored key in front when the truncated
    /// listing dropped it.
    public static func visibleKeys(
        listed: [String],
        stored: String,
        storedIsRecognized: Bool
    ) -> [String] {
        if stored.isEmpty || listed.contains(stored) { return listed }
        guard storedIsRecognized else { return listed }
        return [stored] + listed
    }

    /// Keep `stored` when it is among the visible rows. Otherwise use `fallback`
    /// (empty or unrecognized keys). A recognized-but-truncated key must already
    /// have been prepended by ``visibleKeys``.
    public static func resolvedKey(
        stored: String,
        visible: [String],
        fallback: String?
    ) -> String {
        if visible.contains(stored) { return stored }
        return fallback ?? stored
    }
}
