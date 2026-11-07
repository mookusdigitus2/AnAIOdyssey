// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Plain-text payloads for the system share sheet.
///
/// Chats, documents, and research results share as UTF-8 text. Image sharing
/// uses the on-disk file (see the UI `ShareableImageFile` wrapper); this type
/// only supplies titles and text bodies so the format can be tested without
/// SwiftUI.
public enum WorkspaceShareContent {
    /// Turns a stored role into a share-sheet heading ("You", "Assistant", …).
    public static func roleLabel(_ role: String) -> String {
        switch role.lowercased() {
        case "user": "You"
        case "assistant": "Assistant"
        case "system": "System"
        default: role.localizedCapitalized
        }
    }

    /// A chat transcript: optional title, then labeled turns.
    public static func chatPlainText(
        title: String,
        messages: [(role: String, content: String)]
    ) -> String {
        var lines: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            lines.append(trimmedTitle)
            lines.append("")
        }
        for message in messages {
            let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            lines.append("\(roleLabel(message.role)):")
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A document: title, blank line, then body. Drops empty parts.
    public static func documentPlainText(title: String, content: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return trimmedContent }
        if trimmedContent.isEmpty { return trimmedTitle }
        return "\(trimmedTitle)\n\n\(trimmedContent)"
    }

    /// A research result: query, thread (or summary), then cited sources.
    public static func researchPlainText(
        query: String,
        summary: String,
        thread: [(role: String, content: String)],
        sources: [(title: String, url: String, snippet: String)]
    ) -> String {
        var parts: [String] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            parts.append(trimmedQuery)
        }

        let threadText = chatPlainText(title: "", messages: thread)
        if !threadText.isEmpty {
            parts.append(threadText)
        } else {
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                parts.append(trimmedSummary)
            }
        }

        if !sources.isEmpty {
            var blocks = ["Sources"]
            for source in sources {
                var block: [String] = []
                let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = source.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { block.append(title) }
                if !url.isEmpty { block.append(url) }
                if !snippet.isEmpty { block.append(snippet) }
                if !block.isEmpty {
                    blocks.append(block.joined(separator: "\n"))
                }
            }
            if blocks.count > 1 {
                parts.append(blocks.joined(separator: "\n\n"))
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// SharePreview title for a single message: first line, or a role fallback.
    public static func messageShareTitle(role: String, content: String) -> String {
        let firstLine = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.isEmpty {
            return "\(roleLabel(role)) message"
        }
        if firstLine.count <= 48 {
            return firstLine
        }
        return String(firstLine.prefix(47)) + "…"
    }

    /// SharePreview title for an image: caption, otherwise the filename stem.
    public static func imageShareTitle(caption: String?, filename: String) -> String {
        if let caption {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Image" : stem
    }
}
