// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Incrementally strips tool fences from streamed assistant text.
enum AgentStreamingFilter {
    static func visibleText(from accumulated: String, tags: Set<String>, adapter: RemoteLLMProtocolAdapter?) -> String {
        let stripped = adapter?.stripToolBlocks(from: accumulated, tags: tags)
            ?? AgentToolParser.stripToolBlocks(from: accumulated, tags: tags)
        return bufferPartialFences(in: stripped, tags: tags)
    }

    /// Hides output once an unclosed known tool fence starts.
    private static func bufferPartialFences(in text: String, tags: Set<String>) -> String {
        guard let openRange = text.range(of: "```", options: .backwards) else {
            return text
        }
        let afterOpen = text[openRange.upperBound...]
        if afterOpen.contains("```") { return text }
        let tagLine = afterOpen.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? String(afterOpen)
        let candidate = tagLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tags.contains(candidate) || tags.contains(where: { candidate.hasPrefix($0) }) {
            return String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
