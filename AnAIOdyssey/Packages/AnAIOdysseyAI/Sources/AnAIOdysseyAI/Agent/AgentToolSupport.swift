// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Shared helpers used across the agent tools to keep their output and input parsing consistent.
///
/// Centralizes the conventions every tool follows: truncating large previews,
/// formatting dates, splitting the model's "title on line 1, body after" input,
/// scraping trailing `key: value` metadata, and resolving ids by prefix.
enum AgentToolSupport {
    /// Max characters of content echoed back into a tool result before truncation (keeps the model's context small).
    static let previewLimit = 8_000
    /// Max number of items any `list_*` tool will enumerate.
    static let listLimit = 50

    /// Truncates `text` to `limit`, appending a marker; reports whether truncation occurred.
    static func truncate(_ text: String, limit: Int = previewLimit) -> (preview: String, truncated: Bool) {
        guard text.count > limit else {
            return (text, false)
        }
        return (String(text.prefix(limit)) + "\n... (truncated)", true)
    }

    /// Formats a date compactly for tool listings.
    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Splits content into a title (first line) and body (the rest), the convention for create tools.
    static func parseTitleBody(from content: String, defaultTitle: String = "Untitled") -> (title: String, body: String) {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultTitle
        let body = lines.dropFirst().joined(separator: "\n")
        return (title, body)
    }

    /// Strips trailing `key: value` metadata lines off the end of `lines`, returning them as a dictionary.
    ///
    /// Mutates `lines` in place (removing the consumed metadata) so the caller is
    /// left with just the body. Stops at the first non-metadata line; keys must be
    /// letters/underscores so prose like "Note: ..." isn't mistaken for metadata.
    static func parseMetadataLines(from lines: inout [String]) -> [String: String] {
        var metadata: [String: String] = [:]
        // Walk backwards consuming `key: value` lines until one doesn't qualify.
        while let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            let parts = last.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].allSatisfy({ $0.isLetter || $0 == "_" }) else {
                break
            }
            metadata[parts[0].lowercased()] = parts[1]
            lines.removeLast()
        }
        return metadata
    }

    /// Resolves an item by exact id, or by a unique id prefix, tolerating the abbreviated ids models often produce.
    ///
    /// Returns `nil` for an empty input or an ambiguous prefix (more than one match).
    static func resolveByID<T>(
        _ idOrPrefix: String?,
        in items: [T],
        id: (T) -> String
    ) -> T? {
        guard let idOrPrefix = idOrPrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        // Prefer an exact id match.
        if let exact = items.first(where: { id($0) == idOrPrefix }) {
            return exact
        }
        // Otherwise accept a prefix match only if it's unambiguous.
        let matches = items.filter { id($0).hasPrefix(idOrPrefix) }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension String {
    /// Returns `nil` for an empty string, simplifying optional-coalescing of parsed fields.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
