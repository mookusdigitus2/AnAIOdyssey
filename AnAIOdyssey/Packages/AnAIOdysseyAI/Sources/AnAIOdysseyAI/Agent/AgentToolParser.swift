// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIConnect

/// Parses the agent's *text-based* tool-calling protocol out of raw LLM output.
///
/// Rather than relying on a provider's structured function-calling API (which the
/// small local models don't support reliably), tools are invoked by emitting
/// fenced markdown code blocks whose language tag is a tool name, e.g.:
///
/// ```read_document
/// <document-id>
/// ```
///
/// This parser extracts those blocks for execution and strips them from the text
/// shown to the user, and also parses the inner `<<<FIND>>>/<<<REPLACE>>>` syntax
/// used by the document editor. All functions are pure and regex-driven.
public enum AgentToolParser {
    /// Tags used to build the fenced-block regex. (Note: the registry dispatches a
    /// wider set of tools by name; this set seeds the parser's pattern.)
    public static let toolTags: Set<String> = [
        "read_document",
        "edit_document",
        "create_document",
        "write_document",
        "run_research",
        "search_memory",
        "save_memory",
    ]

    /// Parses fenced ```toolname blocks from LLM text (mirrors Python `parse_tool_blocks`).
    public static func parseToolBlocks(from text: String, tags: Set<String> = toolTags) -> [AgentToolBlock] {
        ToolCallParsing.parseToolBlocks(from: text, tags: tags.isEmpty ? toolTags : tags)
    }

    /// Removes fenced tool blocks from assistant-visible text.
    public static func stripToolBlocks(from text: String, tags: Set<String> = toolTags) -> String {
        ToolCallParsing.stripToolBlocks(from: text, tags: tags.isEmpty ? toolTags : tags)
    }

    /// Parses `<<<FIND>>>...<<<REPLACE>>>...<<<END>>>` edit blocks.
    ///
    /// This is the inner format for `edit_document`: each block pairs the exact
    /// text to find with its replacement. Returns the ordered list of edits to apply.
    public static func parseEditBlocks(from content: String) -> [(find: String, replace: String)] {
        // `.` spans newlines so multi-line find/replace bodies are captured whole.
        let pattern = #"<<<FIND>>>\n(.*?)\n<<<REPLACE>>>\n(.*?)\n<<<END>>>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var edits: [(find: String, replace: String)] = []
        for match in regex.matches(in: content, options: [], range: range) {
            // Group 1 is the find text, group 2 is the replacement.
            guard
                match.numberOfRanges >= 3,
                let findRange = Range(match.range(at: 1), in: content),
                let replaceRange = Range(match.range(at: 2), in: content)
            else {
                continue
            }
            edits.append((find: String(content[findRange]), replace: String(content[replaceRange])))
        }
        return edits
    }
}
