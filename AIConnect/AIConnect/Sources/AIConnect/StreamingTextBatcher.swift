// SPDX-License-Identifier: MIT
import Foundation

/// Batches a growing streamed transcript into display-worthy snapshots.
///
/// Streaming LLM responses arrive as many small chunks; publishing every chunk
/// to the UI forces a layout/render pass per token, which is the dominant
/// battery cost of streaming. This batcher only emits a new snapshot when the
/// text reaches a display boundary — a completed sentence or a line/carriage
/// return — and `finish` flushes the full remaining text at the end (so text
/// shorter than one sentence is still rendered, just once).
public struct StreamingTextBatcher: Sendable {
    /// Character count of the last snapshot handed to the UI.
    private var emittedCount = 0

    public init() {}

    public mutating func reset() {
        emittedCount = 0
    }

    /// The next display snapshot for the cumulative streamed text, or `nil`
    /// when no new boundary has been crossed since the last emission (i.e. the
    /// screen should not be updated yet).
    public mutating func displayText(for cumulative: String) -> String? {
        if cumulative.count < emittedCount {
            // The stream was rewritten shorter (e.g. a new agent round or a
            // sanitizer pass) — show it as-is and continue from there.
            emittedCount = cumulative.count
            return cumulative
        }
        let boundary = Self.lastBoundaryLength(of: cumulative)
        guard boundary > emittedCount else { return nil }
        emittedCount = boundary
        return String(cumulative.prefix(boundary))
    }

    /// Records text that was displayed out-of-band (e.g. a tool-status line
    /// composed by the caller), so later boundaries are measured against it.
    public mutating func markDisplayed(_ text: String) {
        emittedCount = text.count
    }

    /// The final snapshot: always the full text, emitted exactly once at the
    /// end of the stream regardless of boundaries.
    public mutating func finish(_ cumulative: String) -> String {
        emittedCount = cumulative.count
        return cumulative
    }

    /// Length of the longest prefix that ends at a display boundary: a line
    /// feed / carriage return, or sentence punctuation (optionally trailed by
    /// closing quotes/brackets) followed by whitespace. Requiring whitespace
    /// after punctuation avoids treating decimals ("3.14") or URLs as
    /// sentence ends.
    static func lastBoundaryLength(of text: String) -> Int {
        let punctuation: Set<Character> = [".", "!", "?", "…"]
        let closing: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}"]
        var lastBoundary = 0
        var count = 0
        var pendingPunctuation = false
        for character in text {
            count += 1
            // isNewline covers \n, \r, the \r\n grapheme cluster, and Unicode
            // line separators.
            if character.isNewline {
                lastBoundary = count
                pendingPunctuation = false
            } else if character.isWhitespace {
                if pendingPunctuation { lastBoundary = count }
                pendingPunctuation = false
            } else if punctuation.contains(character) {
                pendingPunctuation = true
            } else if closing.contains(character) {
                // Closers between punctuation and whitespace keep the boundary
                // alive (e.g. «He said "stop." » cuts after the quote).
            } else {
                pendingPunctuation = false
            }
        }
        return lastBoundary
    }
}
